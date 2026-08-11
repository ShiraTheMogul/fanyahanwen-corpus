# frozen_string_literal: true

module ChengyuGames
  class OpponentPicker
    def initialize(mode:, opponent:, used_family_ids:, score:, random: Random.new)
      @mode = mode.to_s
      @opponent = opponent.to_s
      @used_family_ids = Array(used_family_ids).map(&:to_i).uniq
      @score = score.to_i
      @random = random
    end

    def seed
      scope = pool
      if @mode == "hard" && @random.rand < 0.55
        compounds = scope.where("han_character_count > 4 OR contains_punctuation = ?", true)
        scope = compounds if compounds.exists?
      end

      count = scope.count
      return nil if count.zero?

      fallback = nil
      [30, count].min.times do
        candidate = scope.offset(@random.rand(count)).first
        fallback ||= candidate
        return candidate if candidate && continuation_count(candidate.last_character_codepoint_id, excluding: [candidate.chengyu_id]).positive?
      end

      fallback || scope.first
    end

    def pick(required_character_codepoint_id:)
      candidates = candidate_forms(required_character_codepoint_id)
      return nil if candidates.empty?
      return candidates.sample(random: @random) if @opponent == "random"

      ranked_candidates(candidates).first
    end

    def alternatives(required_character_codepoint_id:, limit: 5)
      candidates = candidate_forms(required_character_codepoint_id)
      ordered = @opponent == "random" ? candidates.shuffle(random: @random) : ranked_candidates(candidates)
      ordered.first(Integer(limit))
    end

    def continuation_count(required_character_codepoint_id, excluding: [])
      scope = pool.where(first_character_codepoint_id: required_character_codepoint_id)
      excluded = (@mode == "zen" ? [] : @used_family_ids) + Array(excluding).map(&:to_i)
      scope = scope.where.not(chengyu_id: excluded.uniq) if excluded.any?
      scope.distinct.count(:chengyu_id)
    end

    private

    def pool
      ChengyuForm.game_pool(@mode)
    end

    def candidate_forms(required_character_codepoint_id)
      scope = pool.where(first_character_codepoint_id: required_character_codepoint_id)

      if @mode == "zen"
        fresh = scope.where.not(chengyu_id: @used_family_ids)
        scope = fresh if @used_family_ids.any? && fresh.exists?
      elsif @used_family_ids.any?
        scope = scope.where.not(chengyu_id: @used_family_ids)
      end

      choose_family_representatives(scope.to_a)
    end

    def choose_family_representatives(forms)
      forms.group_by(&:chengyu_id).values.map do |family_forms|
        if @mode == "hard"
          family_forms.min_by do |form|
            [form.compound? ? 0 : 1, form.is_display_form? ? 0 : 1, -form.han_character_count.to_i, form.form_text]
          end
        else
          family_forms.min_by { |form| [form.is_display_form? ? 0 : 1, form.form_text] }
        end
      end
    end

    def ranked_candidates(candidates)
      branch_counts = branch_counts_for(candidates)
      candidates.sort_by do |form|
        branches = branch_counts.fetch(form.last_character_codepoint_id, 0)
        [adaptive_cost(form, branches), @random.rand]
      end
    end

    def branch_counts_for(candidates)
      last_ids = candidates.map(&:last_character_codepoint_id).compact.uniq
      return {} if last_ids.empty?

      scope = pool.where(first_character_codepoint_id: last_ids)
      scope = scope.where.not(chengyu_id: @used_family_ids) if @mode != "zen" && @used_family_ids.any?
      scope.group(:first_character_codepoint_id).distinct.count(:chengyu_id)
    end

    def adaptive_cost(form, branches)
      case @mode
      when "zen"
        # Relaxed play tries to keep the chain alive for as long as possible.
        -branches
      when "hard"
        # Hard play deliberately aims at low-branching junctions. Long/compound
        # Chengyu are favoured so the broader corpus appears regularly.
        compound_bonus = form.compound? ? -4.0 : 0.0
        length_bonus = -0.35 * [form.han_character_count.to_i - 4, 0].max
        branches + compound_bonus + length_bonus
      else
        # Standard play gets gradually less generous as the player's streak
        # grows, while avoiding a dead end when a live continuation exists.
        target = [12 - (@score / 3), 3].max
        dead_end_penalty = branches.zero? ? 8.0 : 0.0
        (Math.log2(branches + 1) - Math.log2(target + 1)).abs + dead_end_penalty
      end
    end
  end
end
