# frozen_string_literal: true

class CharacterInputCodesController < ApplicationController
  layout "application"

  def index
    @query = params[:q].to_s.strip
    @system_id = params[:system_id].to_s.strip
    @match_mode = params[:match].presence_in(%w[exact prefix]) || "prefix"
    limit = params.fetch(:limit, 100).to_i.clamp(1, 100)

    # The HTML browser needs the system list. Candidate JSON requests already
    # name their system, so scanning DISTINCT system_id on every keystroke only
    # adds latency.
    @systems = request.format.json? ? [] : CharacterInputCode.distinct.order(:system_id).pluck(:system_id)
    @results = CharacterInputCode.includes(:character_codepoint).order(:system_id, :code).limit(limit)
    @results = @results.where(system_id: @system_id) if @system_id.present?

    if @query.present?
      # RIME codes are commonly one ASCII letter (for example Cangjie `a`).
      # Do not mistake those for a request to look up the Latin character A.
      if CharacterData::IndexableCharacter.single?(@query) && !@query.ascii_only?
        character = CharacterCodepoint.find_by(codepoint: @query.ord)
        @results = character ? @results.where(character_codepoint_id: character.id) : @results.none
      elsif @match_mode == "exact"
        @results = @results.where(code: @query).reorder(:code, :id)
      else
        # A lexical half-open range lets SQLite use idx_character_input_codes_lookup
        # (system_id, code). LIKE 'pg%' commonly degrades into a large scan under
        # SQLite's default LIKE collation. For ASCII RIME codes, pg <= code < ph
        # is the same prefix set and is index-friendly.
        upper = prefix_upper_bound(@query)
        @results = if upper
          @results.where("character_input_codes.code >= ? AND character_input_codes.code < ?", @query, upper)
        else
          @results.where("character_input_codes.code >= ?", @query)
        end
        # The exact code naturally sorts before longer strings with the same
        # prefix, so :code, :id keeps exact-first behavior without a CASE sort.
        @results = @results.reorder(:code, :id)
      end
    end

    respond_to do |format|
      format.html
      format.json do
        render json: @results.map { |row|
          {
            character: row.character_codepoint.chr,
            codepoint: "U+#{row.character_codepoint.codepoint.to_s(16).upcase}",
            code: row.code,
            system_id: row.system_id,
            kind: row.kind,
            source: row.source
          }
        }
      end
    end
  end

  private

  # Return the smallest Unicode string greater than every string beginning with
  # `value`. RIME codes are normally ASCII, but this works for arbitrary Unicode
  # codepoints as well.
  def prefix_upper_bound(value)
    codepoints = value.codepoints
    index = codepoints.length - 1
    while index >= 0
      if codepoints[index] < 0x10FFFF
        codepoints[index] += 1
        return codepoints.first(index + 1).pack("U*")
      end
      index -= 1
    end
    nil
  end
end
