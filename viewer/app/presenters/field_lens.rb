module FieldLens
  GROUP_ORDER = [
	"Strokes & radicals", # TODO: Component listings.
	"Variants", # TODO: Make these hyperlink to new pages. 
	"Pronunciation",
    "Input", # TODO: Wubi, SKIP
	"Education notes", # Education system; include Japanese, HSK, etc information later. Qianziwen / Baijiaxing No.?
    "Dictionary indices",
    "Encodings & mappings",
    "Ideographic Research Group (IRG) sources",
    "Other"
  ].freeze
  
  FIELD_ORDER_BY_GROUP = {
	  "Pronunciation" => {
		exact: %w[
			kFanqie
			kMandarin
			kHanyuPinyin
			kHanyuPinlu
			kTGHZ2013
			kXHC1983
			kCantonese
			laoguoyin
			kKorean
			kHangul
			kVietnamese
			kZhuang
		  ],
		prefix: [ # There are three Japanese parts, so let's put these together.
			"kJapanese"
		]
	}
}.freeze
	
	# These fields go unused; either because they're superseded by better data or because they're handled by something else. 
	HIDDEN_FIELDS = %w[
		kDefinition
		kSimplifiedVariant
		kTraditionalVariant
		# When we have a user-selected romanisation display, these become noisy
		# duplicates. We keep the "canonical" readings (kMandarin/kCantonese) and
		# hide the extra Mandarin reading sources by default.
		kHanyuPinyin
		kHanyuPinlu
		kTGHZ2013
		kXHC1983
		cedict_pinyin
		kangxi_gloss
		cedict_def
	].freeze
	
	# Pinyin helpers. 
	def self.pinyin_for(text)
	  PinYin.of_string(text, :unicode).join(" ")
	end
	def self.label_with_pinyin(text)
	  return text unless text.match?(/\p{Han}/)   # only if it contains Han chars
	  "#{text} (#{pinyin_for(text)})"
	end
	def self.pinyin_titlecase(han, chunks: nil)
		# Get syllables with tone marks, e.g. ["hàn", "yǔ"]
		# See gem ruby-pinyin
		syllables = PinYin.of_string(han, :unicode)
		
		# Capitalise each syllable "hàn" -> "Hàn"
		capitalised = syllables.map do |s|
			s[0].upcase + s[1..]
		end
		
		# Glue syllables together. This is self-asserted in `pinyin-chunks` because Chinese laughs at the idea of word boundaries by default. 
		# Example: ["Hàn","Yǔ","Pín","Lǜ"] with [2,2] -> ["Hànyǔ", "Pínlǜ"]
		if chunks.is_a?(Array)
		words = []
		i = 0
		
		chunks.each do |n|
			part = capitalised[i, n]      # take n syllables starting at i
			first = part.first            # keep first syllable capitalised
			rest = part.drop(1).map(&:downcase)  # downcase the rest (Yǔ -> yǔ)
			
			words << ([first] + rest).join
			i += n
		end
		
		return words.join(" ")
	end
	
	# Fallback: just space-separate syllables if no chunking rules exist.
	capitalised.join(" ")
	end
	
	# Hide unused and/or redundant fields
	def self.hidden_prop?(prop)
		# prop is one row from character_properties
		
		field = prop.field   # e.g. "kDefinition", "ccdict_simp"
		value = prop.value   # e.g. "挛"

		# If it's in the hard "never show" list, hide it.
		return true if HIDDEN_FIELDS.include?(field)

		# Hide CC-CEDICT mapping fields from the generic "Properties" list
		# This is a quirk of the CCDICT database: It hard codes trad/simp fields. 
		# Example: trad is 反, simp is also 反 -> don't show simp.
		if field == "cedict_simp" || field == "cedict_trad"
		  # If trad == simp, hide simp
		  if field == "cedict_simp" && value.present? && value == prop.character_codepoint&.chr
			return true
		  end

		  return true
		end

			# If we didn't hit any of the "hide" rules above, we show the property.
			false
	
		end

	# Kangxi Formatting Helper
	# Format Kangxi text with dictionary-style line breaks. Quick and dirty port of a Python system I had for a Pleco version.
	# - Keep 【註】 inline (never linebreak around it)
	# - Treat 又【...】 as a "new section": insert TWO newlines before it (unless at start)
	# - Insert ONE newline before 【...】 only when:
	#     - we are not at the start
	#     - we have seen some real text since the last break
	#     - the last meaningful char we output is NOT 見
	#     - we are NOT between consecutive bracket tags
	def self.format_kangxi(text)
	  return "" if text.nil?

	  s = text.to_s

	  # ---- 1) Tokenise into meaningful chunks ----
	  #
	  # We want four token types:
	  # - "又【...】"  (special)
	  # - "【註】"     (special note tag)
	  # - "【...】"    (generic bracket tags)
	  # - everything else (plain text)
	  tokens = s.scan(/又【[^】]*】|【註】|【[^】]*】|[^【]+/)

	  out = +""

	  # This flag means: "have we output any non-whitespace text since the last newline break?"
	  seen_text_since_break = false

	  # Helper: find the last non-whitespace character already written to `out`
	  last_nonspace_char = lambda do
		i = out.length - 1
		while i >= 0 && out.getbyte(i).chr =~ /\s/
		  i -= 1
		end
		i >= 0 ? out[i] : nil
	  end

	  # Helper: should we suppress a break because the previous meaningful char was 見 ?
	  # This is used to denote when Kangxi suggests looking at another character within a definition. 
	  # May be buggy? 
	  ends_with_jian = lambda do
		last_nonspace_char.call == "見"
	  end

	  tokens.each_with_index do |tok, idx|
		prev = idx > 0 ? tokens[idx - 1] : nil
		nxt  = idx < tokens.length - 1 ? tokens[idx + 1] : nil

		is_note   = (tok == "【註】")
		is_youb   = tok.start_with?("又【")          # "又【...】"
		is_brack  = tok.start_with?("【") && tok.end_with?("】") && !is_note
		prev_brack = prev && prev.start_with?("【") && prev.end_with?("】") && prev != "【註】"
		next_brack = nxt  && nxt.start_with?("【")  && nxt.end_with?("】")  && nxt != "【註】"

		# ---- 2) Apply breaking rules before we append the token ----

		if is_youb
		  # If we have "...。又【...】", we want the "又" to start on a NEW line.
		  # Otherwise, keep the stronger section break.
		  if out.strip != ""
			if last_nonspace_char.call == "。"
			  out << "\n"
			else
			  out << "\n\n"
			end
			seen_text_since_break = false
		  end

		elsif is_brack
		  # If the source has "。　又\n【...】" (note the full-width space U+3000),
		  # we still want "又" to start a new line. The trailing "\s*" handles cases
		  # where the data already has a newline after 又.
		  if out =~ /。[\s\u3000]*又[\s\u3000]*\z/u # account for ASCII whitespace + ideographic space (U+3000)
			out.sub!(/。[\s\u3000]*又[\s\u3000]*\z/u, "。\n又")
			# Do not add anything here, or 【...】 is pushed down.
		  else
			# Normal rule: maybe break before 【...】
			should_break =
			  out.strip != "" &&
			  seen_text_since_break &&
			  !ends_with_jian.call &&
			  !prev_brack && !next_brack

			if should_break
			  out << "\n"
			  seen_text_since_break = false
			end
		  end
		 
		elsif is_note
		  # 【註】 stays inline
		end

		out << tok

		# If the token has any non-whitespace in it, we've now seen text since the last break.
		if tok.strip != ""
		  seen_text_since_break = true
		end
	  end

	  # finishing touches
	  # "又" in Kangxi is a strong "new sense" marker.
	  # When it appears after a full stop (。), it should start on a fresh line.
	  #
	  # This catches forms like:
	  #   "...。　又若若，垂貌。"
	  #   "...。　又\n【...】"
	  out.gsub!(/。[\s\u3000]*又/u, "。\n又")

	  # Occasionally the data has "】　又" without the full stop.
	  # That still reads as a new sub-entry, so we linebreak there too.
	  out.gsub!(/】[\s\u3000]*又/u, "】\n又")

	  out.strip
	end

	def self.sort_groups(group_hash)
	  group_hash.sort_by { |group_name, _| GROUP_ORDER.index(group_name) || 999 }
	end

	def self.sort_grouped(group_hash)
	  sort_groups(group_hash).map do |group_name, props|
		[group_name, sort_props_within_group(group_name, props)]
	  end
	end


  # 3) Decide group for any given field
	def self.group_for(field)
		return "Strokes & radicals" if field.start_with?("kRS") || field == "kTotalStrokes"
		return "Pronunciation" if 
			field.start_with?("kFanqie") || field.start_with?("kMandarin") || field.start_with?("kHanyuPinyin") ||
			field.start_with?("kHanyuPinlu") || field.start_with?("kTGHZ2013") || field.start_with?("kXHC1983") ||
			field.start_with?("kCantonese") || field.start_with?("kJapanese") || field.start_with?("kKorean") ||
			field.start_with?("kHangul") || field.start_with?("kVietnamese") || field.start_with?("kZhuang") || field == "laoguoyin"
		return "Input" if %w[kCangjie kFourCornerCode kMainlandTelegraph kTaiwanTelegraph].include?(field)
		return "Variants" if field.include?("Variant") || field.start_with?("kSemantic") || field.start_with?("kSimplified") || field.start_with?("cedict_simp") || field.start_with?("kTraditional")
		return "Dictionary indices" if field.include?("kPhonetic") || field.match?(/hanyu/i) || field.start_with?("kMorohashi") || field.include?("kCihai") || field.start_with?("kFenn") || field.match?("kCowles") || field.include?("DaeJaweon") || field.start_with?("kFennIndex") || field.start_with?("kGSR") || field.include?("KangXi") || field.match?("kLau") || field.match?("kMatthews") || field.match?("kMeyerWempe") || field.match?("kNelson") || field.start_with?("kSBGY") || field.match?("kSMSZD2003Index") || field.start_with?("kSMSZD2003Index") || field.start_with?("kHKGlyph") || field.match?("kKarlgren")
		return "Education notes" if field.match?("kGradeLevel") || field.match?("kKoreanEducationHanja")
		return "Ideographic Research Group (IRG) sources" if field.start_with?("kIRG_") || field == "kIICore"
		return "Encodings & mappings" if field.match?(/\A(kBigFive|kUnihanCore2020|kJis|kCCCII|kEACC|kTGH|kJoyoKanji|kMojiJoho|kXerox)\b/) || field.start_with?("kRSUnicode") || field.start_with?("kCNS") || field.start_with?("kGB") || field.start_with?(/kjis/i)
		
		"Other"
	end
  
	def self.sort_props_within_group(group_name, props)
		rules = FIELD_ORDER_BY_GROUP[group_name] || {}
		exact = rules[:exact] || []
		prefix = rules[:prefix] || []
	
		props.sort_by do |p|
		exact_rank = exact.index(p.field)
		if exact_rank
			[0, exact_rank, p.source.to_s, p.value.to_s]
		else
			prefix_rank = prefix.index { |pre| p.field.start_with?(pre) }
		if prefix_rank
			[1, prefix_rank, p.field, p.source.to_s, p.value.to_s]
		else
			[2, p.field, p.source.to_s, p.value.to_s]
			end
			end
		end
	end


  # Make the labels pretty and comprehensible for someone who does not spend half their life staring at Unihan
  # What do users struggle with? Many of these are academic dictionary references, but someone wouldn't know that just looking. What is a "kMatthews"?
  # TODO: Make all this good (research Unihan more)
  
  # kHangul: A value of 0 corresponds to KS X 1001, a value of 1 corresponds to KS X 1002, a value of E corresponds to 한문 교육용 기초 한자 (漢文敎育用基礎漢字), and a value of N corresponds to 인명용 한자 (人名用漢字). A value of X indicates that a K-source was formerly at that code point but was later removed.
  # Improve presentation?
  
  # Manually replace some of Unihan's "kX" stuff with explicit, transparent wording, and/or characters when Chinese calques appear (e.g. Fanqie). 
  PRETTY = {
	"kDefinition" => "Unihan Definition",
	"kFanqie" => {
			han: "反切", 
			pinyin: true,
			pinyin_chunks: [2],
		},
	"kHanyuPinyin" =>  {
			han: "漢語拼音", 
			pinyin: true,
			pinyin_chunks: [2, 2],
		},
	"kHanyuPinlu" => "漢語頻率 Hànyǔ Pínlǜ (Pronunciation + Frequency)",
	"kTang" => "Tang dynasty pronunciation", # T’ang Poetic Vocabulary by Hugh M. Stimson, Far Eastern Publications, Yale University 1976. Method unclear.
	"laoguoyin" => "Old National Pronunciation 老國音",
    "kCangjie" => "倉頡輸入法 Cāngjié input method",
    "kFourCornerCode" => "角號碼檢字法 Four-corner input method",
	"kKorean" => "Korean (Yale)",
	"kKangXi" => {
	  han: "康熙",
	  pinyin: true,
	  pinyin_chunks: [2]
	},
	"kIRGKangXi" => {
	  prefix: "IRG ",
	  han: "康熙",
	  pinyin: true,
	  pinyin_chunks: [2]
	},
	"kangxi_gloss" => "康熙字典解釋",
	"kKoreanName" => "Official Korean name since", # 인명용 한자 (人名用漢字) - 1,800 glyph set used for educational purposes. Unihan says it is a year that corresponds to the list; 2015 or 2018. There have been updates in 2022 and 2024 but they do not have the data: Improve? 
	"kGradeLevel" => "Hong Kong Primary School Grade (朗文初級中文詞典, 2001)",
	"cedict_def" => "CC-CEDICT Definition",
	"cedict_simp" => "CC-CEDICT Simplified",
	"kPhonetic" => "Phonetic class" # Ten Thousand Characters: An Analytic Dictionary, by G. Hugh Casey, S.J. Hong Kong: Kelly and Walsh, 1980. https://analyticphysics.com/Language/Chinese%20Phonetic%20Groups.htm
  }.freeze
	
	# and some automatic stuff in case
	def self.label_for(field)
		# 1) Look up a "pretty label" rule for this field in PRETTY.
		# If PRETTY does not contain this field, v will be nil.
		v = PRETTY[field]

		# 2) If PRETTY stores a plain String for this field, just use it.
		# Example: "kKangxi" => "康熙 Kāngxī"
		return v if v.is_a?(String)

		# 3) If PRETTY stores a Hash for this field, we build the label from parts.
		if v.is_a?(Hash)
			# A) Pull pieces out of the hash.
			# v[:han] means "the value stored under the key :han"
			han = v[:han].to_s
			
			# Optional text that appears BEFORE the Han label (like "IRG ").
			prefix = v[:prefix].to_s
			
			# Optional explanation shown at the end in parentheses.
			extra = v[:extra]

			# B) Start building the label as a string.
			# At minimum we want prefix + han.
			label = "#{prefix}#{han}"

			# C) If this hash says pinyin: true, we generate pinyin for the Han text.
			if v[:pinyin] && han.match?(/\p{Han}/)
				py = pinyin_titlecase(han, chunks: v[:pinyin_chunks])
				# Add a space then pinyin: "漢語頻率 Hànyǔ Pínlǜ"
				label = "#{label} #{py}"
			end
			
			# D) If there is extra text, add it in parentheses.
			# This is the long form of the ternary operator:
			#   extra ? "(...)" : ""
			if extra
				label = "#{label} (#{extra})"
			end

		# E) Return the final label we built.
		return label
	end

		# 4) Final fallback: field wasn't in PRETTY at all.
		# Remove a leading "k" then split CamelCase.
		field.sub(/\Ak/, "").gsub(/([a-z])([A-Z])/, '\1 \2')
	end

end # eof
