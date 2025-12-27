module CangjieKeymap
	CANGJIE_KEYMAP = {
		"A" => "日", 
		"B" => "月", 
		"C" => "金", 
		"D" => "木", 
		"E" => "水", 
		"F" => "火", 
		"G" => "土", 
		"H" => "竹", 
		"I" => "戈", 
		"J" => "十", 
		"K" => "大", 
		"L" => "中", 
		"M" => "一", 
		"N" => "弓", 
		"O" => "人", 
		"P" => "心", 
		"Q" => "手", 
		"R" => "口", 
		"S" => "尸", 
		"T" => "廿", 
		"U" => "山", 
		"V" => "女", 
		"W" => "田", 
		"X" => "難", 
		"Y" => "卜", 
		"Z" => "重",
	}
	CANGJIE_REVERSE = CANGJIE_KEYMAP.invert
	def self.latin_to_han(str)
		result = ""
		str.upcase.each_char do |ch|
			mapped = CANGJIE_KEYMAP[ch]
			result << (mapped || ch)
		end
		result
	end
	def self.han_to_latin(str)
		result = ""
		str.each_char do |ch|
			mapped = CANGJIE_REVERSE[ch]
			result << (mapped || ch)
		end
		result
	end
	def self.normalise_cangjie(str)
		convstr = han_to_latin(str)
		result = ""
		convstr.each_char do |ch|
			if ch =~ /[A-Za-z]/
				result << ch.upcase
				end
			end
		result
	end
end
