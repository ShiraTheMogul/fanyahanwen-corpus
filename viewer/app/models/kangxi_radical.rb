# frozen_string_literal: true

class KangxiRadical < ApplicationRecord
  # Seeded from a CSV derived from the Wikipedia Kangxi radicals table.
  #
  # Important: column names may differ depending on how the seed/import was generated
  # (e.g. :pinyin_mandarin vs :mandarin_pinyin). The views should rely on stable
  # semantic methods defined here, so the UI does not break if columns change.

  def mandarin_pinyin
    read_any(:mandarin_pinyin, :pinyin_mandarin, :pinyin)
  end

  def vietnamese
    read_any(:vietnamese, :vietnamese_sino_vietnamese, :sino_vietnamese)
  end

  def japanese
    read_any(:japanese, :japanese_on_kun_romaji, :japanese_reading)
  end

  def korean
    read_any(:korean, :korean_hanja_hangul_romaja, :korean_reading)
  end

  private

  def read_any(*keys)
    keys.each do |k|
      return self[k] if has_attribute?(k) && self[k].present?
    end
    nil
  end
end
