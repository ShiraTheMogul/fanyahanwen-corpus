# frozen_string_literal: true

# Interface locale codes used by Rails and by the future Crowdin export layout.
#
# ALL contains every staged locale. SELECTABLE contains only locales that are
# currently exposed by the site UI; placeholder-only locales remain hidden
# until a human translation is ready for review.
module InterfaceLocales
  SOURCE = :en

  ALL = %i[
    en
    ja ryu
    vie
    ko jje
    cmn lzh yue nan wuu cjy hak hsn gan czh cnp csp dng
    zha
    ru
  ].freeze

  SELECTABLE = %i[en lzh].freeze

  DISPLAY_NAMES = {
    en: "English",
    ja: "Japanese",
    ryu: "Okinawan",
    vie: "Vietnamese",
    ko: "Korean",
    jje: "Jeju",
    cmn: "Mandarin",
    lzh: "Literary Chinese",
    yue: "Cantonese",
    nan: "Hokkien",
    wuu: "Shanghainese",
    cjy: "Jin Chinese",
    hak: "Hakka Chinese",
    hsn: "Xiang Chinese",
    gan: "Gan Chinese",
    czh: "Hui Chinese",
    cnp: "Northern Pinghua",
    csp: "Southern Pinghua",
    dng: "Dungan",
    zha: "Zhuang",
    ru: "Russian"
  }.freeze
end
