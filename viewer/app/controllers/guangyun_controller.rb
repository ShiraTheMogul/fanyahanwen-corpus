# frozen_string_literal: true

class GuangyunController < ApplicationController
  # Guangyun dictionary browser.
  #
  # IMPORTANT:
  # This controller used to be a "sanity check" for importer debugging.
  # The project already has working browsers for Kangxi radicals and Shuowen components.
  # Guangyun should follow that same pattern: index lists categories.
  #
  # For backwards compatibility with any existing routes that still point
  # /dictionary/guangyun -> GuangyunController#index, we make this action
  # render the real category browser index.
  def index
    scope = CharacterProperty.where(source: "Guangyun (Siku)", field: "guangyun_category")

    @categories = scope
      .select(:value)
      .distinct
      .order(:value)
      .pluck(:value)

    @counts = {
      categories: @categories.length,
      characters: scope.select(:character_codepoint_id).distinct.count,
      rows: scope.count
    }

    render "guangyun_categories/index"
  end
end
