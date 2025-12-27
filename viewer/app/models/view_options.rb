# frozen_string_literal: true

# Central list of UI "view option" values.
#
# - Controllers should not depend on view helpers for constants.
# - Use to help views and controllers reference the same source.
module ViewOptions
  # What text can be used for ruby (reading annotation) above the headword.
  # Keep these as simple symbols because we store them in the session.
  RUBY_SOURCES = [
    :mandarin,
    :cantonese,
    # Old National Pronunciation (老國音) from laoguoyin_readings.
    # The actual output format is controlled by the "Phoneticization conventions" picker.
    :laoguoyin,
    :japanese_kana,
    :japanese_on,
    :japanese_kun,
    :korean_yale,
    :korean_hangul,
    :vietnamese,
	:zhuang, # Ancient Zhuang Character Dictionary (古壮字字典), 1989, ISBN 7-5363-0614-8
	:tang,
	:fanqie
  ].freeze

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