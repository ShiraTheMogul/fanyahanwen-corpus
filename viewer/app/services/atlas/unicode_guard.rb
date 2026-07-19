# frozen_string_literal: true

module Atlas
  # Atlas data contains a large amount of Han text. Encoding damage is therefore
  # data corruption, not a presentation issue. Builders and release checks call
  # this guard before publishing generated files.
  class UnicodeGuard
    class InvalidUnicode < StandardError; end

    REPLACEMENT_CHARACTER = "\uFFFD"
    COMMON_MOJIBAKE = [
      [0x00E4, 0x00B8],
      [0x00E5, 0x0153],
      [0x00E6, 0x0153],
      [0x00E6, 0x00BC],
      [0x00E6, 0x2013],
      [0x00E6, 0x2014],
      [0x00B5, 0x00A3, 0x00D8, 0x00DA]
    ].map { |codepoints| codepoints.pack("U*") }.freeze

    def self.validate!(value, context: "atlas data")
      new.validate!(value, context: context)
    end

    def validate!(value, context: "atlas data")
      walk(value, context)
      true
    end

    private

    def walk(value, context)
      case value
      when Hash
        value.each do |key, child|
          check_string(key.to_s, "#{context} key")
          walk(child, "#{context}.#{key}")
        end
      when Array
        value.each_with_index { |child, index| walk(child, "#{context}[#{index}]") }
      when String
        check_string(value, context)
      end
    end

    def check_string(value, context)
      string = value.dup.force_encoding(Encoding::UTF_8)
      raise InvalidUnicode, "#{context} is not valid UTF-8" unless string.valid_encoding?
      raise InvalidUnicode, "#{context} contains the Unicode replacement character" if string.include?(REPLACEMENT_CHARACTER)

      marker = COMMON_MOJIBAKE.find { |candidate| string.include?(candidate) }
      raise InvalidUnicode, "#{context} appears to contain mojibake near #{marker.inspect}" if marker
    end
  end
end
