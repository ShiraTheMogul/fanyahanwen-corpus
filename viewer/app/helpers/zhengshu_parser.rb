# Parses traditional place-value numerals into an Integer.
# Based on my old 正數 converter
# Supports: 零一二三四五六七八九十百千萬億兆
# Options:
#   allow_you:     accept 有 as a gap marker
#   allow_abbrev:  accept 廿/卅/卌 as tens abbreviations
#   allow_variants: accept common variant numerals (弍弎亖拾佰仟)
#   TODO: more anti-fraud numerals
module ZhengshuParser
  DIGITS = {
    "零" => 0, "〇" => 0,
    "一" => 1, "二" => 2, "三" => 3, "四" => 4, "五" => 5,
    "六" => 6, "七" => 7, "八" => 8, "九" => 9
  }.freeze

  VARIANT_DIGITS = {
    "壹" => 1, "貳" => 2, "弍" => 2, "兩" => 2,
    "參" => 3, "叁" => 3, "弎" => 3,
    "肆" => 4, "亖" => 4,
    "伍" => 5, "陸" => 6, "柒" => 7, "捌" => 8, "玖" => 9
  }.freeze

  SMALL_UNITS = { "十" => 10, "拾" => 10, "百" => 100, "佰" => 100, "千" => 1000, "仟" => 1000 }.freeze
  BIG_UNITS = { "萬" => 10_000, "亿" => 100_000_000, "億" => 100_000_000, "兆" => 1_000_000_000_000 }.freeze

  ABBREV_TENS = { "廿" => 20, "卅" => 30, "卌" => 40 }.freeze

  module_function

  def parse(str, allow_you: false, allow_abbrev: false, allow_variants: true)
    s = str.to_s.strip
    raise ArgumentError, "Empty" if s.empty?

    if allow_you
      s = s.delete("有")
    else
      raise ArgumentError, "Contains 有" if s.include?("有")
    end

    if allow_abbrev
      ABBREV_TENS.each { |ch, v| s = s.gsub(ch, v == 20 ? "二十" : v == 30 ? "三十" : "四十") }
    else
      raise ArgumentError, "Contains abbreviations" if s.match?(/[廿卅卌]/)
    end

    digits = DIGITS.dup
    digits.merge!(VARIANT_DIGITS) if allow_variants

    total = 0
    section = 0
    number = 0

    chars = s.chars
    i = 0
    while i < chars.length
      ch = chars[i]
      if digits.key?(ch)
        number = digits[ch]
      elsif SMALL_UNITS.key?(ch)
        unit = SMALL_UNITS[ch]
        if number == 0
          # 十六 -> 1*10 + 6
          number = 1 if unit == 10
        end
        section += number * unit
        number = 0
      elsif BIG_UNITS.key?(ch)
        unit = BIG_UNITS[ch]
        section += number
        total += section * unit
        section = 0
        number = 0
      else
        raise ArgumentError, "Unsupported character: #{ch}"
      end
      i += 1
    end

    total + section + number
  end
end
