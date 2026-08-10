# frozen_string_literal: true

class CharacterStructuresController < ApplicationController
  layout "application"

  def index
    @query = params[:q].to_s.strip
    @mode = params[:mode].presence_in(%w[exact fuzzy]) || "fuzzy"
    @limit = params.fetch(:limit, 50).to_i.clamp(1, 100)
    @difficult_component_groups = Ids::DifficultComponents.groups
    @results = []
    @query_error = nil

    if @query.present?
      search = Ids::Search.new
      @results = @mode == "exact" ? search.exact(@query, limit: @limit) : search.fuzzy(@query, limit: @limit)
      @query_error = I18n.t("ids_search.incomplete_fuzzy") if @mode == "fuzzy" && !(Ids::Parser.valid?(@query))
    end

    respond_to do |format|
      format.html
      format.json do
        render json: @results.map { |result| serialize_result(result) }
      end
    end
  end

  private

  def serialize_result(result)
    structure = result.structure
    {
      character: structure.glyph,
      codepoint: "U+#{structure.character_codepoint.codepoint.to_s(16).upcase}",
      expression: structure.expression,
      normalized_expression: structure.normalized_expression,
      score: result.score.round(4),
      source: structure.source,
      source_version: structure.source_version,
      source_level: structure.source_level,
      glyph_region: structure.glyph_region
    }
  end
end
