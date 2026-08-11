# frozen_string_literal: true

require "set"

module ChengyuData
  # Finds known Chengyu forms in a displayed corpus body while preserving raw
  # character offsets. Matching is based on each form's Han-only game_key, so
  # normal punctuation differences do not prevent discovery. A match may cross
  # punctuation/spacing, but never a line break and never an arbitrarily large
  # non-Han gap.
  class TextMatcher
    Match = Struct.new(:chengyu_id, :chengyu_form_id, :display_form, :start_offset, :end_offset, :matched_text, keyword_init: true)
    FormRow = Struct.new(:id, :chengyu_id, :form_text, :game_key, :is_display_form, keyword_init: true)

    MAX_NON_HAN_GAP = 8
    EMPTY_CANDIDATES = [].freeze

    class << self
      def current
        return new if defined?(Rails) && Rails.env.test?

        signature = cache_signature
        @cache_mutex ||= Mutex.new
        @cache_mutex.synchronize do
          if !defined?(@cached_signature) || @cached_signature != signature || !defined?(@cached_matcher)
            @cached_matcher = new
            @cached_signature = signature
          end
          @cached_matcher
        end
      end

      def reset_cache!
        @cache_mutex ||= Mutex.new
        @cache_mutex.synchronize do
          @cached_matcher = nil
          @cached_signature = nil
        end
      end

      private

      def cache_signature
        imported = ChengyuImport.order(imported_at: :desc).limit(1).pick(:fingerprint)
        imported.presence || "#{ChengyuForm.count}:#{ChengyuForm.maximum(:id)}"
      rescue ActiveRecord::StatementInvalid
        "unavailable"
      end
    end

    def initialize(forms: nil)
      @candidates_by_first = Hash.new { |hash, key| hash[key] = [] }
      rows = forms ? rows_from_forms(forms) : rows_from_database
      build_candidates(rows)
    end

    def matches(text)
      chars = text.to_s.each_char.to_a
      return [] if chars.empty? || @candidates_by_first.empty?

      han_chars = []
      raw_positions = []
      chars.each_with_index do |char, raw_index|
        next unless han?(char)

        han_chars << char
        raw_positions << raw_index
      end
      return [] if han_chars.length < ChengyuForm::STANDARD_HAN_LENGTH

      matches = []
      han_chars.each_index do |han_index|
        candidates = @candidates_by_first.fetch(han_chars[han_index], EMPTY_CANDIDATES)
        next if candidates.empty?

        candidates.each do |candidate|
          key_chars = candidate.fetch(:key_chars)
          length = key_chars.length
          next if han_index + length > han_chars.length
          next unless same_chars?(han_chars, han_index, key_chars)

          raw_start = raw_positions[han_index]
          raw_end = raw_positions[han_index + length - 1] + 1
          raw_slice_chars = chars[raw_start...raw_end]
          next if raw_slice_chars.include?("\n") || raw_slice_chars.include?("\r")
          next if raw_slice_chars.length > length + MAX_NON_HAN_GAP
          next unless allowed_interstitials?(raw_slice_chars, candidate.fetch(:allowed_non_han))

          raw_slice = raw_slice_chars.join
          form = choose_form(candidate.fetch(:forms), raw_slice)
          matches << Match.new(
            chengyu_id: form.chengyu_id,
            chengyu_form_id: form.id,
            display_form: form.form_text,
            start_offset: raw_start,
            end_offset: raw_end,
            matched_text: raw_slice
          )
        end
      end

      matches.uniq { |match| [match.chengyu_id, match.start_offset, match.end_offset] }
    end

    private

    def rows_from_database
      ChengyuForm
        .where(script_class: ChengyuForm::HARD_SCRIPT_CLASSES)
        .where("han_character_count >= ?", ChengyuForm::STANDARD_HAN_LENGTH)
        .pluck(:id, :chengyu_id, :form_text, :game_key, :is_display_form)
        .map do |id, chengyu_id, form_text, game_key, is_display_form|
          FormRow.new(
            id: id,
            chengyu_id: chengyu_id,
            form_text: form_text,
            game_key: game_key,
            is_display_form: is_display_form
          )
        end
    rescue ActiveRecord::StatementInvalid
      []
    end

    def rows_from_forms(forms)
      Array(forms).filter_map do |form|
        next unless ChengyuForm::HARD_SCRIPT_CLASSES.include?(form.script_class.to_s)
        next if form.han_character_count.to_i < ChengyuForm::STANDARD_HAN_LENGTH
        next if form.game_key.to_s.empty?

        FormRow.new(
          id: form.id,
          chengyu_id: form.chengyu_id,
          form_text: form.form_text,
          game_key: form.game_key,
          is_display_form: form.is_display_form?
        )
      end
    end

    def build_candidates(rows)
      rows.group_by { |row| [row.chengyu_id, row.game_key.to_s] }.each_value do |family_rows|
        key = family_rows.first.game_key.to_s
        next if key.each_char.count < ChengyuForm::STANDARD_HAN_LENGTH
        next unless key.each_char.all? { |char| han?(char) }

        @candidates_by_first[key.each_char.first] << {
          key_chars: key.each_char.to_a.freeze,
          allowed_non_han: allowed_non_han_for(family_rows).freeze,
          forms: family_rows.freeze
        }
      end

      @candidates_by_first.each_value do |candidates|
        candidates.sort_by! { |candidate| -candidate.fetch(:key_chars).length }
        candidates.freeze
      end
      @candidates_by_first.freeze
    end


    def allowed_non_han_for(forms)
      allowed = Set.new
      forms.each do |form|
        form.form_text.to_s.each_char { |char| allowed << char unless han?(char) }
      end
      if (allowed & Set.new(["，", ",", "、"])).any?
        allowed.merge(["，", ",", "、"])
      end
      allowed
    end

    def allowed_interstitials?(chars, allowed)
      chars.all? do |char|
        han?(char) || char.match?(/\A\s\z/u) || allowed.include?(char)
      end
    end

    def choose_form(forms, raw_slice)
      exact = forms.find { |form| form.form_text == raw_slice }
      exact || forms.find(&:is_display_form) || forms.first
    end

    def same_chars?(haystack, start, needle)
      needle.each_with_index.all? { |char, offset| haystack[start + offset] == char }
    end

    def han?(char)
      char.match?(/\A\p{Han}\z/u)
    end
  end
end
