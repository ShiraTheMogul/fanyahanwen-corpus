# frozen_string_literal: true

# Interface locale registry used by Rails and the future Crowdin export layout.
#
# `status: :public` means the locale may be selected by a request. `:hidden`
# means its catalogue exists for translators, but visitors cannot activate it.
#
# The selector itself is kept behind SELECTOR_VISIBLE so translations can be
# prepared and reviewed before the control is shown in the site header.
module InterfaceLocales
  SOURCE = :en
  SELECTOR_VISIBLE = true
  VALID_STATUSES = %i[public hidden].freeze

  DEFINITIONS = {
    en:  { native_name: "English", status: :public },
    ja:  { native_name: "日本語", status: :hidden },
    ryu: { native_name: "沖縄口", status: :hidden },
    vie: { native_name: "Tiếng Việt", status: :hidden },
    ko:  { native_name: "한국어", status: :hidden },
    jje: { native_name: "제주어", status: :hidden },
    cmn: { native_name: "官話", status: :hidden },
    lzh: { native_name: "文言", status: :public },
    yue: { native_name: "粵語", status: :hidden },
    nan: { native_name: "福建話", status: :hidden },
    wuu: { native_name: "上海閒話", status: :hidden },
    cjy: { native_name: "晉語", status: :hidden },
    hak: { native_name: "客家話", status: :hidden },
    hsn: { native_name: "湘語", status: :hidden },
    gan: { native_name: "贛語", status: :hidden },
    czh: { native_name: "徽語", status: :hidden },
    cnp: { native_name: "北部平話", status: :hidden },
    csp: { native_name: "南部平話", status: :hidden },
    dng: { native_name: "Хуэйзў йүян", status: :hidden },
    zha: { native_name: "Vahcuengh", status: :hidden },
    ru:  { native_name: "Русский", status: :hidden }
  }.freeze

  ALL = DEFINITIONS.keys.freeze
  SELECTABLE = DEFINITIONS.filter_map { |code, definition| code if definition[:status] == :public }.freeze
  DISPLAY_NAMES = DEFINITIONS.transform_values { |definition| definition.fetch(:native_name) }.freeze

  module_function

  def selector_visible?
    SELECTOR_VISIBLE
  end

  def selectable?(code)
    SELECTABLE.include?(code.to_s.to_sym)
  end

  def native_name(code)
    DISPLAY_NAMES.fetch(code.to_s.to_sym)
  end
end
