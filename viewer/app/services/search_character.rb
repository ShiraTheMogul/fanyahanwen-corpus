class SearchCharacter
  def self.call(query, search_type = nil)
    # Determine search type based on query or parameter
    search_type ||= detect_search_type(query)
    
    case search_type
    when :character
      search_by_character(query)
    when :pinyin
      search_by_pinyin(query)
    when :composition
      search_by_composition(query)
    else
      Character.none
    end
  end
  
  private
  
  def self.detect_search_type(query)
    # Heuristic: if query is a single Chinese character
    if query.match?(/\p{Han}/) && query.length == 1
      :character
    # Heuristic: if query looks like pinyin
    elsif query.match?(/^[a-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]+$/i)
      :pinyin
    else
      :composition
    end
  end
  
  def self.search_by_character(char)
    Character.where(hanzi: char)
  end
  
  def self.search_by_pinyin(pinyin)
    # Join with readings table
    Character.joins(:readings)
             .where(readings: { pinyin: pinyin.downcase })
             .distinct
  end
end
