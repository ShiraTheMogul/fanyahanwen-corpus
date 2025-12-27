# frozen_string_literal: true

require "pathname"
require "thread" # Mutex

# Phoneticization::Converters
# -----------------------
#
# This file is a *thin wrapper* around two third‑party conversion libraries:
#   - pingyam-rb (Cantonese)
#   - pinyin-rb  (Mandarin)
#
# Both libraries work well, but their APIs are awkward for Rails code because:
#   - They use integer IDs (0, 1, 2...) to represent schemes.
#   - They expose different class names (Converter vs Py_Converter).
#
# Your app should not care about those details.
#
# So elsewhere in the app, you should be able to write:
#
#   Phoneticization::Converters.mandarin("han4 yu3", to: :gwoyeu)
#   Phoneticization::Converters.cantonese("hoeng1", to: :ipa)
#
module Phoneticization
  module Converters
    class MissingDependencyError < StandardError; end

    # --- Scheme maps ---------------------------------------------------------
    # File: lib/phoneticization/converters.rb
    # Keys: symbols used by the application.
    # Values: integer IDs expected by the upstream library.
    #
    # Source: pinyin-rb README ("Included transcription systems" table). 0..12
    # https://github.com/dohliam/pinyin-rb
    MANDARIN_SCHEMES = {
      pinyin_numbers: 0,
      pinyin_diacritics: 1,
      bopomofo: 2,
      wade_giles: 3,
      mps_ii: 4,
      yale: 5,
      tongyong: 6,
      gwoyeu: 7,
      top: 8,
      palladius: 9,
      exemplars_trad: 10,
      exemplars_simp: 11,
      ipa: 12
    }.freeze



# Extra "schemes" that are not handled by pinyin-rb, but are still Mandarin
# readings that can be selected in the UI. These are lookup-based, not
# conversion-based.
#
# - :laoguoyin_latin  -> laoguoyin_readings.laoguoyin
# - :laoguoyin_zhuyin -> laoguoyin_readings.zhuyin
# - :laoguoyin_ipa    -> laoguoyin_readings.ipa
MANDARIN_EXTRA_SCHEMES = {
  laoguoyin_latin: :laoguoyin,
  laoguoyin_zhuyin: :zhuyin,
  laoguoyin_ipa: :ipa
}.freeze

    # Source: pingyam-rb README ("Included romanization systems" table). 0.10
    # https://github.com/dohliam/pingyam-rb
    CANTONESE_SCHEMES = {
      yale_numbers: 0,
      yale_diacritics: 1,
      cantonese_pinyin: 2,
      sl_wong_numbers: 3,
      sl_wong_diacritics: 4,
      ipa: 5,
      jyutping: 6,
      canton: 7,
      sidney_lau: 8,
      penkyamp_numbers: 9,
      penkyamp_diacritics: 10
    }.freeze

    # --- Public API ----------------------------------------------------------
    #
    # Convert Mandarin romanised text between schemes.
    #
    # `from:` and `to:` must be keys from MANDARIN_SCHEMES.
    #
    # By default we assume the input is Pinyin-with-numbers because
    # that is the most common machine-friendly storage format.
    def self.mandarin(text, from: :pinyin_numbers, to: :pinyin_diacritics, fail_silently: true)
      convert(
        lang: :mandarin,
        text: text,
        from: from,
        to: to,
        fail_silently: fail_silently
      )
    end

    # Convert Cantonese romanised text between schemes.
    #
    # We default to :jyutping as the common "data" format.
    def self.cantonese(text, from: :jyutping, to: :jyutping, fail_silently: true)
      convert(
        lang: :cantonese,
        text: text,
        from: from,
        to: to,
        fail_silently: fail_silently
      )
    end

    # --- Implementation details ---------------------------------------------
    #
    # The upstream libs load conversion databases from files on disk.
    # Initialising a converter repeatedly is expensive, so we cache them.
    @mandarin_mutex = Mutex.new
    @cantonese_mutex = Mutex.new
    @mandarin_cache = {}
    @cantonese_cache = {}

    def self.convert(lang:, text:, from:, to:, fail_silently:)
      return text if text.nil? || text == ""

      from_id, to_id = scheme_ids(lang, from, to)

      begin
        converter = cached_converter(lang, from_id)
        return converter.convert_line(text, to_id)
      rescue MissingDependencyError
        raise unless fail_silently
        return text
      rescue StandardError
        # In views we want a page, not a 500.
        raise unless fail_silently
        return text
      end
    end
    private_class_method :convert

    def self.scheme_ids(lang, from_key, to_key)
      map =
        case lang
        when :mandarin then MANDARIN_SCHEMES
        when :cantonese then CANTONESE_SCHEMES
        else
          raise ArgumentError, "Unknown language: #{lang.inspect}"
        end

      from_id = map[from_key.to_sym]
      to_id = map[to_key.to_sym]

      if from_id.nil?
        raise ArgumentError, "Unknown #{lang} scheme for from=: #{from_key.inspect}. Allowed: #{map.keys.sort.inspect}"
      end
      if to_id.nil?
        raise ArgumentError, "Unknown #{lang} scheme for to=: #{to_key.inspect}. Allowed: #{map.keys.sort.inspect}"
      end

      [from_id, to_id]
    end
    private_class_method :scheme_ids

    # The upstream libraries define these classes:
    #   - pinyin-rb:   Py_Converter
    #   - pingyam-rb:  Converter
    #
    # Your app is expected to require those files somewhere during boot.
    # If you want a single predictable place, create:
    #   config/initializers/Phoneticization.rb
    # and require the vendored library files there.
    def self.cached_converter(lang, from_id)
      case lang
      when :mandarin
        ensure_mandarin_loaded!
        @mandarin_mutex.synchronize do
          @mandarin_cache[from_id] ||= Py_Converter.new(from_id)
        end
      when :cantonese
        ensure_cantonese_loaded!
        @cantonese_mutex.synchronize do
          @cantonese_cache[from_id] ||= Converter.new(from_id)
        end
      else
        raise ArgumentError, "Unknown language: #{lang.inspect}"
      end
    end
    private_class_method :cached_converter

    def self.ensure_mandarin_loaded!
      return if defined?(Py_Converter)

      raise MissingDependencyError, <<~MSG
        pinyin-rb is not loaded (Py_Converter is undefined).

        Fix:
          1) Put lib_pinyin.rb somewhere in the project (commonly under vendor/ or lib/vendor/).
          2) Require it during app boot, e.g. in config/initializers/Phoneticization.rb:
               require Rails.root.join("vendor", "pinyin", "lib_pinyin.rb")

        The pinyin-rb README explains the required database file layout:
          - a folder named `pinyin/` in the project root containing `pinyinbiao`.
      MSG
    end
    private_class_method :ensure_mandarin_loaded!

    def self.ensure_cantonese_loaded!
      return if defined?(Converter)

      raise MissingDependencyError, <<~MSG
        pingyam-rb is not loaded (Converter is undefined).

        Fix:
          1) Put lib_pingyam.rb somewhere in the project (commonly under vendor/ or lib/vendor/).
          2) Require it during app boot, e.g. in config/initializers/Phoneticization.rb:
               require Rails.root.join("vendor", "pingyam", "lib_pingyam.rb")

        The pingyam-rb README explains the required database file layout:
          - a folder named `pingyam/` in the project root containing `pingyambiu`.
      MSG
    end
    private_class_method :ensure_cantonese_loaded!
  end
end
