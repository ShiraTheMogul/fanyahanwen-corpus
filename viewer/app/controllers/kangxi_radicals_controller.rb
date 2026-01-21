# frozen_string_literal: true

class KangxiRadicalsController < ApplicationController
  # Smaller default page improves perceived speed (less HTML, faster layout).
  DEFAULT_PER = 50
  MAX_PER = 200

  before_action :load_radical, only: [:show, :chars]
  before_action :load_pagination, only: [:show, :chars]

  def index
    @radicals = KangxiRadical.order(:number)
  end

  # The main page renders fast: the character table is loaded via Turbo Frame.
  def show
    base = CharacterRadicalMembership.where(radical_number: @radical.number)
    @total = base.count(:all)

    # For the "is the index built?" banner, don't do COUNT(*) over 100k rows.
    @memberships_exist = CharacterRadicalMembership.exists?
  end

  # Turbo Frame endpoint: renders just the character list + pagination controls.
  def chars
    base = CharacterRadicalMembership.where(radical_number: @radical.number)
    @total = base.count(:all)

    memberships = CharacterRadicalMembership
      .joins(:character_codepoint)
      .where(radical_number: @radical.number)
      .select("character_codepoints.*, character_radical_memberships.additional_strokes AS additional_strokes")
      .order("character_radical_memberships.additional_strokes ASC, character_codepoints.codepoint ASC")
      .limit(@per)
      .offset((@page - 1) * @per)
      .to_a

    @characters = memberships
    cc_ids = @characters.map(&:id)

    @unihan_defs =
      if cc_ids.empty?
        {}
      else
        CharacterProperty
          .where(character_codepoint_id: cc_ids, field: "kDefinition")
          .pluck(:character_codepoint_id, :value)
          .to_h
      end

    render layout: false
  end

  private

  def load_radical
    @radical = KangxiRadical.find_by!(number: params[:number].to_i)
  end

  def load_pagination
    per = params[:per].to_i
    per = DEFAULT_PER if per <= 0
    per = MAX_PER if per > MAX_PER
    @per = per

    page = params[:page].to_i
    page = 1 if page <= 0
    @page = page
  end
end
