class Reading < ApplicationRecord
  belongs_to :character
  # Fields might include: pinyin, zhuyin, cantonese, korean_hangul, korean_romanized, etc.
  # type field to distinguish (e.g., 'mandarin', 'cantonese', 'fanqie')
end
