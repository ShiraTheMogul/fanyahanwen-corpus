# frozen_string_literal: true

class CharacterGamesController < ApplicationController
  layout "application"

  def deconstruction
    @rounds = round_builder.ids_rounds(limit: 24)
  end

  def construction
    # Free-form IDS toy. Results come from the existing structure-search JSON
    # endpoint, so this action does not need its own game dataset.
  end

  def components
    @rounds = round_builder.component_rounds(limit: 30)
    @stroke_counts = Ids::DifficultComponents.groups.map { |group| group[:stroke_count].to_s }
    @stroke_classes = Ids::DifficultComponents::STROKE_CLASSES.map do |key, labels|
      { key: key, han: labels[:han], english: labels[:english], representative: labels[:representative] }
    end
  end

  private

  def round_builder
    @round_builder ||= CharacterGames::RoundBuilder.new
  end
end
