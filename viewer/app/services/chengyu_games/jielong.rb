# frozen_string_literal: true

module ChengyuGames
  class Jielong
    MODES = %w[standard hard zen].freeze
    OPPONENTS = %w[adaptive random].freeze

    def initialize(mode:, opponent:, used_family_ids: [], score: 0, random: Random.new)
      @mode = MODES.include?(mode.to_s) ? mode.to_s : "standard"
      @opponent = OPPONENTS.include?(opponent.to_s) ? opponent.to_s : "adaptive"
      @used_family_ids = Array(used_family_ids).map(&:to_i).select(&:positive?).uniq
      @score = score.to_i
      @random = random
    end

    attr_reader :mode, :opponent

    def start
      form = picker.seed
      return { ok: false, error: "No playable Chengyu are imported for this mode." } unless form

      used = append_used(@used_family_ids, form.chengyu_id)
      continuations = continuation_count(form, used)
      {
        ok: true,
        mode: mode,
        opponent: opponent,
        computer: present(form),
        current_form_id: form.id,
        used_family_ids: used,
        continuation_count: continuations,
        round_over: continuations.zero?,
        outcome: continuations.zero? ? "player_stuck" : "continue",
        message: continuations.zero? ? "This opening has no legal continuation in the current mode. Start a new round." : nil
      }
    end

    def submit(answer:, current_form_id:)
      current = load_form(current_form_id)
      return invalid("The current Chengyu is no longer available. Start a new round.") unless current

      used_before = append_used(@used_family_ids, current.chengyu_id)
      required_id = current.last_character_codepoint_id
      candidate_result = resolve_answer(answer, required_id)
      return candidate_result unless candidate_result[:ok]

      player_form = candidate_result.fetch(:form)
      if mode != "zen" && used_before.include?(player_form.chengyu_id)
        return invalid("That Chengyu family has already been used in this round.", code: "repeat")
      end

      used_after_player = append_used(used_before, player_form.chengyu_id)
      reply_picker = build_picker(used_family_ids: used_after_player, score: @score + 1)
      computer_form = reply_picker.pick(required_character_codepoint_id: player_form.last_character_codepoint_id)

      unless computer_form
        return {
          ok: true,
          mode: mode,
          opponent: opponent,
          user: present(player_form),
          computer: nil,
          current_form_id: nil,
          used_family_ids: used_after_player,
          continuation_count: 0,
          round_over: true,
          outcome: "computer_stuck",
          message: "No legal reply remains for the computer. You completed the chain."
        }
      end

      used_after_computer = append_used(used_after_player, computer_form.chengyu_id)
      remaining = build_picker(used_family_ids: used_after_computer, score: @score + 1)
        .continuation_count(computer_form.last_character_codepoint_id)

      {
        ok: true,
        mode: mode,
        opponent: opponent,
        user: present(player_form),
        computer: present(computer_form),
        current_form_id: computer_form.id,
        used_family_ids: used_after_computer,
        continuation_count: remaining,
        round_over: remaining.zero?,
        outcome: remaining.zero? ? "player_stuck" : "continue",
        message: remaining.zero? ? "The computer closed the chain: there is no legal unused continuation." : nil
      }
    end

    def alternatives(current_form_id:, limit: 5)
      current = load_form(current_form_id)
      return { ok: false, alternatives: [], error: "The current Chengyu is no longer available." } unless current

      used = append_used(@used_family_ids, current.chengyu_id)
      forms = build_picker(used_family_ids: used, score: @score).alternatives(
        required_character_codepoint_id: current.last_character_codepoint_id,
        limit: limit
      )

      {
        ok: true,
        required_character: current.last_character,
        alternatives: forms.map { |form| present(form) }
      }
    end

    private

    def picker
      build_picker(used_family_ids: @used_family_ids, score: @score)
    end

    def build_picker(used_family_ids:, score:)
      OpponentPicker.new(
        mode: mode,
        opponent: opponent,
        used_family_ids: used_family_ids,
        score: score,
        random: @random
      )
    end

    def resolve_answer(answer, required_character_codepoint_id)
      text = normalize_answer(answer)
      return invalid("Type a Chengyu before submitting.", code: "blank") if text.empty?

      pool = ChengyuForm.game_pool(mode)
      exact = pool.where(form_text: text).to_a
      candidates = exact

      if candidates.empty? && punctuation_or_han_only?(text)
        key = han_key(text)
        candidates = pool.where(game_key: key).to_a if key.present?
      end

      if candidates.empty?
        known = known_form_for(text)
        if known
          return invalid(mode_mismatch_message(known), code: "mode_mismatch", known: true)
        end
        return invalid("That answer is not in the imported Chengyu corpus.", code: "unknown", known: false, rejected_answer: text)
      end

      chained = candidates.select { |form| form.first_character_codepoint_id == required_character_codepoint_id }
      if chained.empty?
        required = CharacterCodepoint.find_by(id: required_character_codepoint_id)&.chr
        starts = candidates.map(&:first_character).compact.uniq.join(" / ")
        return invalid("The next Chengyu must begin with #{required}. This answer begins with #{starts}.", code: "wrong_chain", known: true)
      end

      family_ids = chained.map(&:chengyu_id).uniq
      if family_ids.length > 1
        return invalid("That punctuation-free spelling matches more than one Chengyu family. Type the exact attested form.", code: "ambiguous", known: true)
      end

      form = chained.min_by { |candidate| [candidate.form_text == text ? 0 : 1, candidate.is_display_form? ? 0 : 1, candidate.form_text] }
      { ok: true, form: form }
    end

    def known_form_for(text)
      exact = ChengyuForm.find_by(form_text: text)
      return exact if exact
      return nil unless punctuation_or_han_only?(text)

      key = han_key(text)
      key.present? ? ChengyuForm.find_by(game_key: key) : nil
    end

    def mode_mismatch_message(form)
      if mode == "standard" || mode == "zen"
        if form.han_character_count.to_i != 4 || !form.is_strict_han?
          "That Chengyu is in the corpus, but this mode uses four-character Han-only forms. Hard Mode includes longer compound forms."
        else
          "That Chengyu is known, but it is not playable in this mode."
        end
      else
        "That Chengyu is known, but its script form is not playable in Hard Mode."
      end
    end

    def load_form(id)
      ChengyuForm
        .includes(chengyu: [:forms, :attestations, :readings, :senses, :etymologies])
        .find_by(id: id)
    end

    def present(form)
      loaded = if form.association(:chengyu).loaded? && form.chengyu.association(:forms).loaded?
        form
      else
        load_form(form.id)
      end
      ChengyuData::EntryPresenter.new(loaded).to_h
    end

    def continuation_count(form, used)
      build_picker(used_family_ids: used, score: @score)
        .continuation_count(form.last_character_codepoint_id)
    end

    def append_used(used, family_id)
      (Array(used).map(&:to_i) + [family_id.to_i]).uniq
    end

    def normalize_answer(value)
      value.to_s.unicode_normalize(:nfc).strip.gsub(/\s+/u, "")
    rescue Encoding::CompatibilityError
      value.to_s.strip.gsub(/\s+/u, "")
    end

    def han_key(text)
      text.each_char.select { |char| char.match?(/\A\p{Han}\z/u) }.join
    end

    def punctuation_or_han_only?(text)
      text.each_char.all? { |char| char.match?(/\A(?:\p{Han}|\p{P})\z/u) }
    end

    def invalid(message, code: "invalid", **extra)
      { ok: false, error: message, code: code }.merge(extra)
    end
  end
end
