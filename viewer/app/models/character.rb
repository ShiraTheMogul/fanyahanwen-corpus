class Character < ApplicationRecord
  has_many :readings
  has_many :definitions
  
  # For composition searching, you might want:
  # - radical field (string)
  # - stroke_count (integer)
  # - decomposition (text) - if you get data from elsewhere
end

# Potential radical search system
def self.by_radical(radical)
  where(radical: radical)
end

def self.by_stroke_count(min, max = nil)
  max ||= min
  where(stroke_count: min..max)
end
