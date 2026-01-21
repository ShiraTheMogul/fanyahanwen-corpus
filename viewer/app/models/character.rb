class Character < ApplicationRecord
  has_many :readings
  has_many :definitions
  
  # For composition searching, you might want:
  # - radical field (string)
  # - stroke_count (integer)
  # - decomposition (text) - if you get data from elsewhere
end

