# frozen_string_literal: true

class CharacterInputCodesController < ApplicationController
  layout "application"

  def index
    @query = params[:q].to_s.strip
    @system_id = params[:system_id].to_s.strip
    @match_mode = params[:match].presence_in(%w[exact prefix]) || "prefix"
    limit = params.fetch(:limit, 100).to_i.clamp(1, 100)
    @systems = CharacterInputCode.distinct.order(:system_id).pluck(:system_id)
    @results = CharacterInputCode.includes(:character_codepoint).order(:system_id, :code).limit(limit)
    @results = @results.where(system_id: @system_id) if @system_id.present?

    if @query.present?
      # RIME codes are commonly one ASCII letter (for example Cangjie `a`).
      # Do not mistake those for a request to look up the Latin character A.
      if CharacterData::IndexableCharacter.single?(@query) && !@query.ascii_only?
        character = CharacterCodepoint.find_by(codepoint: @query.ord)
        @results = character ? @results.where(character_codepoint_id: character.id) : @results.none
      else
        if @match_mode == "exact"
          @results = @results.where(code: @query).reorder(:code, :id)
        else
          escaped = ActiveRecord::Base.sanitize_sql_like(@query)
          @results = @results.where("character_input_codes.code LIKE ?", "#{escaped}%")
          @results = @results.reorder(Arel.sql("CASE WHEN character_input_codes.code = #{ActiveRecord::Base.connection.quote(@query)} THEN 0 ELSE 1 END"), :code, :id)
        end
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
end
