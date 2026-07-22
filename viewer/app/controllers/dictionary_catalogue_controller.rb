# frozen_string_literal: true

# Generic browser for dictionaries imported into the normalized dictionary tables.
#
# This deliberately follows the existing Kangxi/Shuowen browser pattern:
# - compact index cards;
# - a left information column;
# - a paginated Turbo Frame on the right;
# - stable public identifiers rather than database row IDs in URLs.
class DictionaryCatalogueController < ApplicationController
  DEFAULT_PER = 50
  MAX_PER = 200
  LOOKUP_LIMIT = 100

  before_action :load_work, only: %i[show section entries entry]
  before_action :load_section, only: %i[section entries]
  before_action :load_pagination, only: %i[section entries]

  def index
    @works = DictionaryWork.order(:title, :corpus_work_id).to_a
  end

  def show
    @sections = @work.dictionary_sections.order(:sequence_number).to_a
    @section_groups = @sections.group_by { |section| section.tone.presence || "其他" }

    @lookup_query = normalize_lookup_query(params[:q])
    @lookup_entries = lookup_entries(@lookup_query) if @lookup_query.present?
  end

  def section
    @total = @section.dictionary_entries.count
    @display_character = @section.rhyme_label.to_s.each_char.find { |character| character.match?(/\p{Han}/) }
  end

  def entries
    scope = @section.dictionary_entries
      .includes(:dictionary_readings, :dictionary_entry_characters)
      .order(:sequence_number)

    @total = scope.count
    @entries = scope.limit(@per).offset((@page - 1) * @per).to_a

    render layout: false
  end

  def entry
    @entry = @work.dictionary_entries
      .includes(
        :dictionary_section,
        :dictionary_readings,
        :dictionary_entry_characters,
        :character_codepoints,
        :dictionary_references
      )
      .find_by!(sequence_number: positive_integer!(params[:entry_sequence]))

    @section = @entry.dictionary_section

    @previous_entry = @work.dictionary_entries
      .where("sequence_number < ?", @entry.sequence_number)
      .order(sequence_number: :desc)
      .select(:sequence_number, :headword)
      .first

    @next_entry = @work.dictionary_entries
      .where("sequence_number > ?", @entry.sequence_number)
      .order(:sequence_number)
      .select(:sequence_number, :headword)
      .first
  end

  private

  def load_work
    @work = DictionaryWork.find_by!(corpus_work_id: positive_integer!(params[:corpus_work_id]))
  end

  def load_section
    @section = @work.dictionary_sections.find_by!(sequence_number: positive_integer!(params[:section_sequence]))
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

  def normalize_lookup_query(raw)
    query = raw.to_s.strip
    return nil if query.empty?

    if (match = query.match(/\AU\+([0-9A-Fa-f]{4,6})\z/))
      codepoint = match[1].to_i(16)
      return nil unless codepoint.between?(0, 0x10FFFF)
      return nil if codepoint.between?(0xD800, 0xDFFF)

      return [codepoint].pack("U")
    end

    query
  rescue RangeError
    nil
  end

  def lookup_entries(query)
    base = @work.dictionary_entries
      .includes(:dictionary_section, :dictionary_readings, :dictionary_entry_characters)
      .order(:sequence_number)

    scope = if query.each_char.count == 1
      base.joins(:dictionary_entry_characters)
        .where(dictionary_entry_characters: { glyph: query })
        .distinct
    else
      base.where(headword: query)
    end

    scope.limit(LOOKUP_LIMIT).to_a
  end

  def positive_integer!(value)
    integer = Integer(value, exception: false)
    raise ActiveRecord::RecordNotFound unless integer&.positive?

    integer
  end
end
