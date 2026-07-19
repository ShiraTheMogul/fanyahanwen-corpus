module UnicodeRanges
	HAN_RANGES = [
		(0x3400..0x4DBF),   # Ext A
		(0x4E00..0x9FFF),   # Unified
		(0xF900..0xFAFF),   # Compatibility Ideographs block
		(0x2F800..0x2FA1D), # Compatibility Ideographs Supplement
		(0x20000..0x2A6DF), # Ext B
		(0x2A700..0x2B73F), # Ext C
		(0x2B740..0x2B81D), # Ext D
		(0x2B820..0x2CEAD), # Ext E
		(0x2CEB0..0x2EBE0), # Ext F
		(0x2EBF0..0x2EE5D), # Ext I
		(0x30000..0x3134A), # Ext G
		(0x31350..0x323AF), # Ext H
		(0x323B0..0x33479)  # Ext J
	].freeze

	HAN_LABELS = [
		"Ext A",
		"Unified",
		"Compat",
		"Supp",
		"Ext B",
		"Ext C",
		"Ext D",
		"Ext E",
		"Ext F",
		"Ext I",
		"Ext G",
		"Ext H",
		"Ext J"
	].freeze

	def self.codepoint_of(x)
		return x if x.is_a?(Integer)

		if x.is_a?(String)
			return nil if x.empty?
			return x.ord if x.length == 1
			return x.delete_prefix("U+").to_i(16) if x.match?(/\AU\+[0-9A-Fa-f]+\z/)
			return x.to_i(16) if x.match?(/\A[0-9A-Fa-f]+\z/)
		end

		nil
	end

	def self.han?(char)
		cp = codepoint_of(char)
		return false unless cp
		HAN_RANGES.any? { |r| r.cover?(cp) }
	end

	def self.han_block_label(char)
		cp = codepoint_of(char)
		return nil unless cp

		i = HAN_RANGES.index { |r| r.cover?(cp) }
		i ? HAN_LABELS[i] : nil
	end

	# CSS unicode-range string for all Han blocks we care about.
	# Example: "U+3400-4DBF, U+4E00-9FFF, ..."
	def self.han_css_unicode_range
		HAN_RANGES.map { |r| sprintf("U+%04X-%04X", r.begin, r.end) }.join(", ")
	end

end
