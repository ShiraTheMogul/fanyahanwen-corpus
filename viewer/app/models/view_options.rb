# frozen_string_literal: true

# Central list of UI "view option" values.
#
# Pronunciation source keys and their family grouping come from
# PronunciationRegistry, so imported datasets do not require another hard-coded
# allow-list in the preferences controller or sidebar.
module ViewOptions
  def self.ruby_sources
    PronunciationRegistry.ruby_source_keys
  end

  def self.ruby_source_options
    PronunciationRegistry.ruby_source_options
  end

  def self.ruby_source_groups
    PronunciationRegistry.ruby_source_groups
  end

  # CSS/layout choice for ruby rendering.
  #
  # :verticalside means "vertical ruby, but placed to the side of the glyph".
  # We keep the stored value as-is, but CharactersHelper maps it to :vertical
  # for CSS class purposes.
  RUBY_ORIENTATIONS = [
    :horizontal,
    :verticalside
  ].freeze
end
