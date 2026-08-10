# frozen_string_literal: true

class CharacterInputCodesController < ApplicationController
  layout "application"

  def index
    @query = params[:q].to_s.strip
    @system_id = params[:system_id].to_s.strip
    @systems = CharacterInputCode.distinct.order(:system_id).pluck(:system_id)
    @results = CharacterInputCode.includes(:character_codepoint).order(:system_id, :code).limit(100)
    @results = @results.where(system_id: @system_id) if @system_id.present?

    if @query.present?
      if CharacterData::IndexableCharacter.single?(@query)
        character = CharacterCodepoint.find_by(codepoint: @query.ord)
        @results = character ? @results.where(character_codepoint_id: character.id) : @results.none
      else
        escaped = ActiveRecord::Base.sanitize_sql_like(@query)
        @results = @results.where("character_input_codes.code LIKE ?", "#{escaped}%")
      end
    end
  end
end
