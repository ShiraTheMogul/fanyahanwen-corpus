# frozen_string_literal: true

module CharacterQuery
  # A reading system is "a set of slots". A slot is the tone-blind form of a
  # reading; a slot plus a tone is a narrower query. Each system declares where
  # its readings live in character_properties and how a raw reading is split
  # into slot and tone.
  #
  # Tone handling is per-system on purpose. Stripping every combining mark is
  # wrong for both pinyin and Vietnamese: the diaeresis in "lǜ" and the horn in
  # "ư" are letter distinctions, not tones, and folding them merges slots that
  # are not homophones.
  module ReadingSystem
    # Pinyin tone marks. The diaeresis (U+0308) is deliberately absent — it
    # distinguishes ü from u and must survive normalisation.
    PINYIN_TONE_MARKS = {
      "̄" => 1, # macron
      "́" => 2, # acute
      "̌" => 3, # caron
      "̀" => 4  # grave
    }.freeze
    PINYIN_LETTER_MARKS = ["̈"].freeze

    # Vietnamese: five tone marks, plus unmarked ngang. Horn (U+031B), breve
    # (U+0306) and circumflex (U+0302) are vowel quality and must survive.
    #
    # Tones are integers here, not symbols, so every system's tone is the same
    # type end to end — the slot index keys on it and the query casts it.
    VIETNAMESE_TONE_MARKS = {
      "́" => 1, # sắc
      "̀" => 2, # huyền
      "̉" => 3, # hỏi
      "̃" => 4, # ngã
      "̣" => 5  # nặng
    }.freeze
    VIETNAMESE_TONE_NAMES = {
      1 => :sac, 2 => :huyen, 3 => :hoi, 4 => :nga, 5 => :nang, 6 => :ngang
    }.freeze
    VIETNAMESE_LETTER_MARKS = ["̛", "̆", "̂"].freeze

    # Value used when a mark-toned system carries no mark: pinyin's neutral
    # tone and Vietnamese's unmarked ngang are real tones, not absences.
    NEUTRAL_TONE = { pinyin: 5, vietnamese: 6 }.freeze

    # MIDDLE CHINESE has four tones, 平上去入, and all four are derived here.
    # Only two of them carry a LETTER in Baxter's transcription, which is why
    # the map below has two entries and not four:
    #
    #   平  dang    unmarked — the default, 1,484 characters in this corpus
    #   上  dangX   final X                   803
    #   去  dangH   final H                   999
    #   入  dak     no letter: the stop coda -p/-t/-k is itself the marker, 747
    #
    # 入聲 is defined distributionally rather than by pitch — a checked
    # syllable, which is why it needs no diacritic and cannot take X or H.
    #
    # Checked against the corpus's own parsed 廣韻: of the characters that
    # appear in both, the derived tone agrees with the rime book's own
    # classification in 98.7% of cases, and the residue is characters where
    # Baxter records one reading and 廣韻 another, not a derivation error.
    #
    # X and H are the only case-significant characters in the whole bs2014_mc
    # field — 903 X and 1,111 H, nothing else — which is what a tone letter
    # looks like.
    #
    # 入聲 is different in kind from the other three. Its marker is the stop
    # coda itself, which is part of the syllable and cannot be removed, so dak
    # keeps its k and is a different slot from dang, while dangX and dang
    # share one. Same shape as Mandarin: a tone mark comes off and the
    # syllable underneath is shared.
    #
    # Numbered in the traditional 平上去入 order, so 1 to 4 reads as 四聲.
    #
    # OLD CHINESE IS NOT TREATED THIS WAY, and it was a mistake to try.
    #
    # Old Chinese had no tones; the 上聲 and 去聲 categories descend from the
    # *-ʔ and *-s suffixes rather than coexisting with them. Baxter & Sagart
    # say so in their own notation key: "A hyphen '-' indicates a morpheme
    # boundary. (We provisionally treat all cases of final *s as morphological
    # suffixes.)" So *lˤaŋ and *lˤaŋ-s are a stem and its derivative — two
    # words, the way deal and dealer are two words — not one syllable under
    # two tones.
    #
    # Stripping the suffix to form a shared slot claimed a homophony the
    # source does not: 525 stem/derivative pairs are both attested in this
    # corpus, and every one of them was being merged.
    #
    # Old Chinese therefore takes the reconstruction as it stands, minus only
    # the leading asterisk, which is notation rather than sound.
    BAXTER_MC_TONE_LETTERS = { "X" => 2, "H" => 3 }.freeze
    BAXTER_ENTERING_CODAS = %w[p t k].freeze
    BAXTER_LEVEL = 1
    BAXTER_ENTERING = 4

    # Several fields pack multiple readings into one value separated by " | ",
    # and splitting on whitespace turns that bar into a reading of its own. It
    # then normalises to a slot, so "|" sits in the Old Chinese inventory as
    # though it were a syllable.
    #
    # Only a STANDALONE bar is a separator. Baxter writes uncertainty inside a
    # reading with the same character — *s-[q]ʷi[n|ŋ]-s means the coda is n or
    # ŋ — and that bar is part of the reconstruction.
    SEPARATOR_ONLY = /\A[|,;\/]+\z/

    SUPERSCRIPT_DIGITS = {
      "⁰" => "0", "¹" => "1", "²" => "2", "³" => "3",
      "⁴" => "4", "⁵" => "5", "⁶" => "6", "⁷" => "7",
      "⁸" => "8", "⁹" => "9"
    }.freeze

    # id => definition. `source` is mandatory in every query: the
    # character_properties index is (source, field, value), and SQLite only
    # uses an index from its leading column, so a field-only filter that is
    # not also constrained by codepoint id degrades to a full table scan.
    DEFINITIONS = {
      # `broad` names a companion system holding the rarer attested readings.
      # It is a checkbox on the form, not a second dropdown entry, so someone
      # typing "ba" gets ba without first having to know which of two Mandarin
      # entries to pick.
      "mandarin" => {
        label_key: "character_query.systems.mandarin",
        source: "Unihan_Readings", field: "kMandarin",
        tone: :pinyin, kind: :sinoxenic, script: :latin,
        broad: "mandarin_broad"
      },
      "mandarin_broad" => {
        label_key: "character_query.systems.mandarin_broad",
        source: "Unihan_Readings", field: "kHanyuPinyin",
        tone: :pinyin, kind: :sinoxenic, script: :latin, payload: :hanyu_pinyin,
        hidden: true
      },
      "cantonese" => {
        label_key: "character_query.systems.cantonese",
        source: "Unihan_Readings", field: "kCantonese",
        tone: :trailing_digit, kind: :sinoxenic, script: :latin
      },
      "japanese_on" => {
        label_key: "character_query.systems.japanese_on",
        source: "Unihan_Readings", field: "kJapaneseOn",
        tone: :none, kind: :sinoxenic, script: :kana
      },
      "korean_hangul" => {
        label_key: "character_query.systems.korean_hangul",
        source: "Unihan_Readings", field: "kHangul",
        tone: :none, kind: :sinoxenic, script: :hangul, payload: :colon_prefixed
      },
      "vietnamese" => {
        label_key: "character_query.systems.vietnamese",
        source: "Unihan_Readings", field: "kVietnamese",
        tone: :vietnamese, kind: :sinoxenic, script: :latin
      },
      "zhuang" => {
        label_key: "character_query.systems.zhuang",
        source: "Unihan_Readings", field: "kZhuang",
        tone: :none, kind: :sinoxenic, script: :latin
      },
      "general_chinese" => {
        label_key: "character_query.systems.general_chinese",
        source: "Chao 1983", field: "general_chinese",
        tone: :none, kind: :diasystem, script: :latin
      },

      # Jejueo and Okinawan are their own languages here, siblings of Korean
      # and Japanese rather than varieties beneath them. Both records are
      # thin — 1,839 and 14 characters — so the coverage notice matters more
      # for these than for anything else in the picker.
      "okinawan_shuri" => {
        label_key: "character_query.systems.okinawan_shuri",
        source: "NINJAL Okinawa-go Jiten Data Collection",
        field: "reading.japonic.okinawan_uchinaaguchi_shuri.ninjal",
        tone: :none, kind: :language, script: :latin
      },
      "jejueo" => {
        label_key: "character_query.systems.jejueo",
        # Curly apostrophe in the source string, as recorded.
        source: "Yang, Yang & O’Grady 2020",
        field: "reading.koreanic.jejueo.hangul",
        tone: :none, kind: :language, script: :hangul
      },

      # Reconstructions. Tone is carried inside the transcription as a final
      # letter — Baxter's -X and -H, the Old Chinese -ʔ and -s — so it comes
      # off the slot exactly as a Mandarin tone mark does. See split_baxter.
      # 入聲 is the exception: its marker is the stop coda, which stays.
      "old_chinese_bs2014" => {
        label_key: "character_query.systems.old_chinese_bs2014",
        source: "Baxter & Sagart, 2014", field: "bs2014_oc",
        tone: :verbatim, kind: :reconstruction, script: :latin
      },
      "middle_chinese_bs2014" => {
        label_key: "character_query.systems.middle_chinese_bs2014",
        source: "Baxter & Sagart, 2014", field: "bs2014_mc",
        tone: :baxter_mc, kind: :reconstruction, script: :latin
      },
      "middle_chinese_bs2006" => {
        label_key: "character_query.systems.middle_chinese_bs2006",
        source: "Baxter (with Sagart), 2006", field: "bs2006_mc",
        tone: :baxter_mc, kind: :reconstruction, script: :latin
      },
      "zhongyuan" => {
        label_key: "character_query.systems.zhongyuan",
        source: "周德清, 1324; nk2028/zhongyuan-data, 2023",
        field: "zhongyuan_yinyun_unt",
        tone: :none, kind: :reconstruction, script: :latin
      },
      "menggu_ziyun" => {
        label_key: "character_query.systems.menggu_ziyun",
        source: "Nk2028/menggu-ziyun-data, 2025",
        field: "menggu_ziyun_transcription",
        tone: :none, kind: :reconstruction, script: :latin
      },

      # Not in character_properties: this one lives in its own table.
      "laoguoyin" => {
        label_key: "character_query.systems.laoguoyin",
        source: nil, field: nil, table: :laoguoyin, column: :laoguoyin,
        tone: :trailing_digit, kind: :historical, script: :latin
      }
    }.freeze

    # Topolect systems are not enumerated here. They are discovered from the
    # property fields themselves, so a new import adds systems without a code
    # change — see FamilyRegistry.
    TOPOLECT_FIELD = /\Areading\.(?<branch>[a-z_]+)\.(?<locality>[a-z0-9_]+)\.ipa\z/

    module_function

    # Three registries, one lookup. The static table, the 小學堂 localities,
    # and the corpus's own rime books — which are read through the dictionary
    # tables and so carry work_id where a reading system carries field.
    def definition(id)
      DEFINITIONS[id.to_s] ||
        FamilyRegistry.topolect_definition(id.to_s) ||
        RimeBooks.definition(id.to_s)
    end

    # A rime book is a source of attested spellings (反切, 韻目, 聲調), not of
    # a romanisation. It has no syllable to type, so the callers that build a
    # syllable box ask this first.
    def rime_book?(id)
      definition(id)&.fetch(:kind, nil) == :rime_book
    end

    def known?(id)
      definition(id).present?
    end

    # Has somewhere to read from: a character_properties field, or its own
    # table. A system that satisfies neither must not appear in the picker,
    # because selecting it would silently return nothing.
    def queryable?(id)
      definition = definition(id)
      return false if definition.nil?
      return false if definition[:hidden]

      definition[:field].present? || definition[:table].present? ||
        definition[:work_id].present?
    end

    def label_for(id)
      definition = definition(id)
      return id.to_s if definition.nil?
      return definition[:label].to_s if definition[:label].present?

      I18n.t(definition[:label_key], default: id.to_s)
    end

    def ids
      DEFINITIONS.keys + FamilyRegistry.topolect_system_ids + RimeBooks.system_ids
    end

    # Splits one raw reading into [slot, tone]. `tone` is nil when the system
    # carries no tone, so a tone-bound query against a toneless system can be
    # rejected instead of silently returning everything.
    def split(reading, system_id)
      raw = reading.to_s.strip
      return [nil, nil] if raw.empty?

      case tone_style(system_id)
      when :pinyin
        split_marked(raw, PINYIN_TONE_MARKS, PINYIN_LETTER_MARKS, NEUTRAL_TONE[:pinyin])
      when :vietnamese
        split_marked(raw, VIETNAMESE_TONE_MARKS, VIETNAMESE_LETTER_MARKS, NEUTRAL_TONE[:vietnamese])
      when :trailing_digit then split_trailing_digit(raw)
      when :superscript_digit then split_superscript(raw)
      when :baxter_mc then split_baxter_mc(raw)
      when :verbatim then split_verbatim(raw)
      else [normalise_plain(raw), nil]
      end
    end

    def tone_style(system_id)
      definition(system_id)&.fetch(:tone, :none) || :none
    end

    def slot_of(reading, system_id)
      split(reading, system_id).first
    end

    # Brings a typed spec into the form the data is stored in, before any
    # slot/tone splitting. Two jobs:
    #
    #  1. ASCII ü. Keyboards and IMEs input "lv" for lü and "nv" for nü, so v
    #     is accepted as ü. No pinyin syllable contains v, which makes the
    #     substitution unambiguous. Applied on INPUT ONLY — kMandarin values
    #     never contain v, so the index must not be built through this.
    #  2. Scheme conversion. Someone may type bopomofo, Wade-Giles, Yale or
    #     any other scheme Phoneticization::Converters handles, so the spec is
    #     converted into the scheme the field actually stores: pinyin with
    #     diacritics for Mandarin, jyutping for Cantonese. fail_silently
    #     returns the text untouched if the upstream gem is missing, so a spec
    #     typed in the target scheme always still works.
    def canonicalise_input(spec, system_id, scheme: nil)
      raw = spec.to_s.strip
      return "" if raw.empty?

      raw = convert_scheme(raw, system_id, scheme)
      raw = raw.tr("vV", "\u00FC\u00FC") if tone_style(system_id) == :pinyin
      raw
    end

    def convert_scheme(raw, system_id, scheme)
      return raw if scheme.blank?
      return raw unless defined?(::Phoneticization::Converters)

      scheme = scheme.to_sym
      case tone_style(system_id)
      when :pinyin
        return raw unless ::Phoneticization::Converters::MANDARIN_SCHEMES.key?(scheme)
        return raw if scheme == :pinyin_diacritics

        ::Phoneticization::Converters.mandarin(raw, from: scheme, to: :pinyin_diacritics).to_s.strip
      when :trailing_digit
        return raw unless ::Phoneticization::Converters::CANTONESE_SCHEMES.key?(scheme)
        return raw if scheme == :jyutping

        ::Phoneticization::Converters.cantonese(raw, from: scheme, to: :jyutping).to_s.strip
      else
        raw
      end
    rescue StandardError
      # A conversion failure must never stop the query; the spec as typed is
      # the fallback.
      raw
    end

    # Schemes offered for one system, for the input dropdown. Empty when the
    # system has no converter, so the control can be hidden.
    def input_schemes(system_id)
      return {} unless defined?(::Phoneticization::Converters)

      case tone_style(system_id)
      when :pinyin then ::Phoneticization::Converters::MANDARIN_SCHEMES
      when :trailing_digit then ::Phoneticization::Converters::CANTONESE_SCHEMES
      else {}
      end
    end

    # Parses a user's slot spec. "yi" is tone-blind; "yi1", "yī", "ji6" and
    # "i35" bind a tone. Returns [slot, tone_or_nil].
    #
    # The distinction `split` cannot make on its own: for a mark-toned system,
    # an unmarked reading in the DATABASE is the neutral tone, but an unmarked
    # spec typed by a USER means "any tone". So a tone is bound here only when
    # the spec states one — a mark, or a trailing digit.
    def parse_spec(spec, system_id, scheme: nil)
      raw = canonicalise_input(spec, system_id, scheme: scheme)
      return [nil, nil] if raw.empty?

      # A trailing ASCII digit is always an explicit binding. No slot in any
      # of these systems ends in one.
      if (match = raw.match(/\A(?<body>.+?)(?<digits>\d{1,2})\z/))
        body_slot, = split(match[:body], system_id)
        return [body_slot, match[:digits].to_i] if body_slot.present?
      end

      slot, split_tone = split(raw, system_id)

      tone =
        case tone_style(system_id)
        when :pinyin then marked_tone(raw, PINYIN_TONE_MARKS)
        when :vietnamese then marked_tone(raw, VIETNAMESE_TONE_MARKS)
        # Same rule as the mark-toned systems, for the same reason. In the
        # DATA a bare "dang" is 平聲; from a USER it means "any tone", and
        # should return dang, dangX and dangH alike. Only a stated marker
        # binds. A stop coda is not a stated marker — it is intrinsic, since
        # every "dak" is 入聲 already, so leaving it unbound costs nothing.
        when :baxter_mc then BAXTER_MC_TONE_LETTERS[raw.strip[-1]]
        else split_tone
        end

      [slot, tone]
    end

    # The tone a mark-toned spec explicitly states, or nil when it states none.
    def marked_tone(raw, tone_marks)
      raw.unicode_normalize(:nfd).each_char do |char|
        return tone_marks[char] if tone_marks.key?(char)
      end
      nil
    end

    # "Never yields a tone", which is what the caller actually wants to know:
    # a tone-bound query against such a system is rejected rather than
    # silently returning the whole slot. :verbatim belongs here with :none —
    # Old Chinese had no tones, and the splitter cannot produce one.
    TONELESS_STYLES = %i[none verbatim].freeze

    def toneless?(system_id)
      TONELESS_STYLES.include?(tone_style(system_id))
    end

    # Some fields pack several readings into one value. kHanyuPinyin is
    # "10093.130:xíng,xìng"; kHangul is "유:0E". Everything else splits on
    # whitespace.
    def readings_in(value, system_id)
      raw = value.to_s
      case definition(system_id)&.dig(:payload)
      when :hanyu_pinyin
        raw.split(/\s+/).flat_map { |part| part.split(":", 2).last.to_s.split(",") }
      when :colon_prefixed
        raw.split(/\s+/).map { |part| part.split(":", 2).first }
      else
        raw.split(/\s+/)
      end.map(&:strip).reject(&:empty?).reject { |part| SEPARATOR_ONLY.match?(part) }
    end

    # -- internals ---------------------------------------------------------

    def split_marked(raw, tone_marks, letter_marks, neutral)
      tone = nil
      kept = raw.unicode_normalize(:nfd).each_char.filter_map do |char|
        if tone_marks.key?(char)
          tone ||= tone_marks[char]
          nil
        elsif letter_marks.include?(char)
          char
        elsif combining?(char)
          nil
        else
          char
        end
      end

      slot = kept.join.unicode_normalize(:nfc).downcase.delete("0-9")
      [presence(slot), tone || neutral]
    end

    def split_trailing_digit(raw)
      m = raw.match(/\A(?<body>.*?)(?<digits>\d{1,2})?\z/)
      [presence(m[:body].to_s.downcase), m[:digits]&.to_i]
    end

    def split_superscript(raw)
      digits = +""
      body = raw.each_char.filter_map do |char|
        if SUPERSCRIPT_DIGITS.key?(char)
          digits << SUPERSCRIPT_DIGITS[char]
          nil
        elsif char.match?(/\d/)
          digits << char
          nil
        else
          char
        end
      end.join

      [presence(body.strip), digits.empty? ? nil : digits.to_i]
    end

    # Middle Chinese only. The tone letter is checked before anything else,
    # because X and H are tones only as capitals, and the body is NOT
    # downcased: case is meaningful here and lowering it would be a silent
    # edit to someone's data.
    def split_baxter_mc(raw)
      body = raw.strip
      return [nil, nil] if body.empty?

      final = body[-1]

      if BAXTER_MC_TONE_LETTERS.key?(final)
        [presence(body[0..-2]), BAXTER_MC_TONE_LETTERS[final]]
      elsif BAXTER_ENTERING_CODAS.include?(final)
        [presence(body), BAXTER_ENTERING]
      else
        [presence(body), BAXTER_LEVEL]
      end
    end

    # The reconstruction exactly as recorded, minus the leading asterisk.
    #
    # No tone, because Old Chinese had none. No downcasing, because the
    # capitals are distinct notation — C is an unknown consonant, N a nasal
    # prefix, A a vowel quality — and lowering them merges reconstructions the
    # source keeps apart: *lAjʔ with *lajʔ, *tA with *ta, eight such pairs in
    # this corpus. Nothing else is touched: the hyphens are morpheme
    # boundaries, the periods syllable boundaries, the brackets and
    # parentheses mark uncertainty, and all of it belongs to the form.
    #
    # The asterisk goes because it is on all 4,713 values and distinguishes
    # nothing; dropping it from the stored slot and from a typed spec alike
    # means *lˤaŋ-s and lˤaŋ-s both find the same characters.
    def split_verbatim(raw)
      [presence(raw.sub(/\A\*+/, "").strip), nil]
    end

    def normalise_plain(raw)
      # kZhuang marks uncertain readings with a trailing asterisk ("aek*").
      # The asterisk is an editorial marker, not part of the syllable.
      presence(raw.downcase.delete("*"))
    end

    def combining?(char)
      # Combining Diacritical Marks and the two supplements Unihan actually uses.
      cp = char.ord
      cp.between?(0x0300, 0x036F) || cp.between?(0x1AB0, 0x1AFF) || cp.between?(0x20D0, 0x20FF)
    end

    def presence(string)
      value = string.to_s.strip
      value.empty? ? nil : value
    end
  end
end
