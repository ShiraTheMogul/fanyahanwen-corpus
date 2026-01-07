# lib/zhengshu.rb
#
# Arabic -> Chinese numerals in traditional place-value style seen in texts such as the Rites of Zhou. 
# Supports: 零一二三四五六七八九十百千萬億兆
# Options:
#   use_you:     insert "有" when a place is skipped (e.g., 十有一, 一百有五, 一千有十五)
#   use_abbrev:  use 廿/卅/卌 for 20/30/40 (e.g., 廿一, 卅二, 卌五)
#
module Zhengshu
  DIGITS = %w[零 一 二 三 四 五 六 七 八 九].freeze
  SMALL_UNITS = ["", "十", "百", "千"].freeze

  # 10^4 group units. Index 0 is ones (no unit), then 萬, 億, 兆, ...
  BIG_UNITS = ["", "萬", "億", "兆"].freeze

  # Obscure but useful extensions that could be used at times. Not sure if I'll ever use these. 
  ABBREV_TENS = {
    2 => "廿", # 20
    3 => "卅", # 30
    4 => "卌"  # 40
  }.freeze

  module_function

  def format(n, use_you: false, use_abbrev: false)
    n = Integer(n)
    raise ArgumentError, "negative not supported" if n.negative?
    return DIGITS[0] if n == 0

    groups = split_groups_of_4(n) # lowest first
    out = +""
    wrote_anything = false

    # Go from highest digit to lowest digit
    (groups.length - 1).downto(0) do |gi|
      group_val = groups[gi]
      next if group_val == 0

      group_str = format_group_0_9999(group_val, use_you: use_you, use_abbrev: use_abbrev)

      # If already wrote a higher group and this group has leading zeros (e.g., 0005),
      # we need a "零" bridge: 1000005 => 一百萬零五
      if wrote_anything && group_val < 1000
        out << "零" unless out.end_with?("零")
      end

      out << group_str
      out << big_unit_for_index(gi)
      wrote_anything = true
    end

    out
  end

  def split_groups_of_4(n)
    groups = []
    while n > 0
      groups << (n % 10_000)
      n /= 10_000
    end
    groups
  end

  def big_unit_for_index(i)
    return BIG_UNITS[i] if i < BIG_UNITS.length
    raise ArgumentError, "number too large: add more BIG_UNITS entries (group index #{i})"
  end

  # Formats 0..9999 (no 萬/億/兆 here)
  def format_group_0_9999(n, use_you:, use_abbrev:)
    return "" if n == 0

    # Optional 廿/卅/卌 when the group has no hundreds/thousands.
    # Works for 20..49: 廿, 廿一...; 卅, 卅一...; 卌, 卌一...
    if use_abbrev && n < 100
      tens = n / 10
      ones = n % 10
      if ABBREV_TENS.key?(tens)
        return ABBREV_TENS[tens] if ones == 0
        return "#{ABBREV_TENS[tens]}#{DIGITS[ones]}"
      end
    end

    qian = (n / 1000) % 10
    bai  = (n / 100) % 10
    shi  = (n / 10) % 10
    ge   = n % 10

    parts = +""

    # thousands
    if qian != 0
      parts << DIGITS[qian] << "千"
    end

    # hundreds
    if bai != 0
      parts << DIGITS[bai] << "百"
    else
      # gap between 千 and (十/個)
      if qian != 0 && (shi != 0 || ge != 0)
        parts << (use_you ? "有" : "零")
      end
    end

    # tens
    if shi != 0
      # omit "一" in 10..19 when tens is the highest non-zero in the group
      if shi == 1 && qian == 0 && bai == 0
        parts << "十"
      else
        parts << DIGITS[shi] << "十"
      end
    else
      # gap between 百 and 個
      if (qian != 0 || bai != 0) && ge != 0
        parts << (use_you ? "有" : "零")
      end
    end

    # ones
    if ge != 0
      # classic “十有一” option specifically for 11..19
      if use_you && qian == 0 && bai == 0 && shi == 1
        # If we already wrote "十" above, we want "十有一" not "十一"
        # The "十" is already in parts; just add 有 + digit.
        parts << "有" << DIGITS[ge]
      else
        parts << DIGITS[ge]
      end
    end

    # Clean up possible double "零"/"有" if logic overlaps (rare, but safe)
    parts.gsub!(/零+/, "零")
    parts.gsub!(/有+/, "有")

    parts
  end
end
