module FieldLens
  GROUP_ORDER = [
	"Strokes & radicals", # TODO: Component listings.
	 # TODO: Make these hyperlink to new pages. 
	"Pronunciation",
    "Input", # TODO: Wubi, SKIP
	"Education notes", # Education system; include Japanese, HSK, etc information later. Qianziwen / Baijiaxing No.?
    "Dictionary indices",
    "Encodings & mappings",
    "Ideographic Research Group (IRG) sources",
    "Other"
  ].freeze

	# ------------------------------------------------------------------
	# kRSUnicode / kRSAdobe_Japan1_6 (radical-stroke) formatting
	# ------------------------------------------------------------------
	# These Unihan fields are compact index strings. For most users we want
	# something close to how zi.tools presents it:
	#   土部8畫 共11畫
	#	This is standard formatting seen in a lot of dictionaries and makes Kangxi more interactive. We also have an English version for the Properties section. 
	#
	# We also return a tooltip string so the radical number can be shown on hover.
	# The radical number is useful, but isn't really huge for the average learner. They want to know how to search a dictionary if they're looking at this, not how to recite radicals. 
	#
	# Display contract:
	# - text: short and scannable
	# - tooltip: contains radical number(s) and any extra technical details
	#
	# kRSUnicode gives "radical.additional" only; to compute total strokes we
	# look up the base radical stroke count via the compatibility Kangxi radical
	# block (U+2F00..U+2FD5) and the radical ideograph's kTotalStrokes.
	
	@__kangxi_radical_base_strokes = nil

	# Turn compact property strings into something friendly.
	#
	# context:
	# - :dictionary (default) keeps the short Chinese display used in dictionary blocks
	#   e.g. "土部8畫 共11畫"
	# - :property_list uses a translated/stat style suitable for the Properties list
	#   e.g. "土部 + 8 strokes" (total strokes are typically shown separately)
	def self.display_value_and_tooltip(field, value, context: :dictionary)
		return ["", nil] if value.nil?
		v = value.to_s

		if field.start_with?("kRSUnicode")
			format_krsunicode(v, context: context)
		elsif field == "kRSAdobe_Japan1_6"
			format_krsadobe(v, context: context)
		else
			[v, nil]
		end
	end

	def self.format_krsunicode(raw, context: :dictionary)
		tokens = raw.strip.split(/\s+/)
		parts = []
		tips  = []

		tokens.each do |tok|
			m = tok.match(/\A(?<rad>\d{1,3})(?<apos>'{0,3})\.(?<add>-?\d{1,2})\z/)
			next unless m

			rad = m[:rad].to_i
			apos = m[:apos]
			add = m[:add].to_i

			rad_ideo = kangxi_radical_ideograph(rad)
			base = kangxi_radical_base_strokes(rad)
			total = base.nil? ? nil : (base + add)

			text = if context == :property_list
				"#{rad_ideo}部 + #{I18n.t('dictionary.field_lens.stroke_count', count: add)}"
			else
				ch = "#{rad_ideo}部#{add}畫"
				ch += " 共#{total}畫" if total
				ch
			end
			parts << text

			tip = I18n.t("dictionary.field_lens.kangxi_radical", number: rad)
			unless apos.empty?
				tip += " (#{apostrophe_meaning(apos)})"
			end
			tips << tip
		end

		return [raw, nil] if parts.empty?
		[parts.join(" / "), tips.uniq.join("; ")]
	end

	def self.format_krsadobe(raw, context: :dictionary)
		tokens = raw.strip.split(/\s+/)
		parts = []
		tips  = []

		tokens.each do |tok|
			m = tok.match(/\A(?<cv>[CV])\+(?<cid>\d{1,5})\+(?<rad>\d{1,3})\.(?<form>\d{1,2})\.(?<res>\d{1,2})\z/)
			next unless m

			cv = m[:cv]
			cid = m[:cid].to_i
			rad = m[:rad].to_i
			form = m[:form].to_i
			res = m[:res].to_i
			total = form + res

			rad_ideo = kangxi_radical_ideograph(rad)
			parts << if context == :property_list
				"#{rad_ideo}部 + #{I18n.t('dictionary.field_lens.stroke_count', count: res)}"
			else
				"#{rad_ideo}部#{res}畫 共#{total}畫"
			end

			type = (cv == "C") ? I18n.t("dictionary.field_lens.direct") : I18n.t("dictionary.field_lens.variant")
			tips << I18n.t("dictionary.field_lens.adobe_tooltip", type: type, cid: cid, radical: rad)
		end

		return [raw, nil] if parts.empty?
		[parts.join(" / "), tips.uniq.join("; ")]
	end

	# Back-compat alias: some controller/view code may still call the older name.
	# "radical strokes" here means "base strokes of the radical".
	def self.kangxi_radical_strokes(radical_number)
		kangxi_radical_base_strokes(radical_number)
	end

	def self.kangxi_radical_symbol(radical_number)
		return nil unless radical_number.is_a?(Integer) && radical_number >= 1 && radical_number <= 214
		(0x2F00 + (radical_number - 1)).chr(Encoding::UTF_8)
	end

	def self.kangxi_radical_ideograph(radical_number)
		sym = kangxi_radical_symbol(radical_number)
		return "" if sym.nil?
		# The Kangxi radical block is compatibility characters; NFKC yields the
		# representative CJK ideograph (e.g. "⼟" -> "土").
		require "unicode_normalize/tables"
		sym.unicode_normalize(:nfkc)
	end

	def self.kangxi_radical_base_strokes(radical_number)
		# Lazy cache: { 1 => 1, 2 => 1, ... }
		@__kangxi_radical_base_strokes ||= {}
		return @__kangxi_radical_base_strokes[radical_number] if @__kangxi_radical_base_strokes.key?(radical_number)

		ideo = kangxi_radical_ideograph(radical_number)
		if ideo.nil? || ideo.empty?
			@__kangxi_radical_base_strokes[radical_number] = nil
			return nil
		end

		cc = CharacterCodepoint.find_by(codepoint: ideo.ord)
		unless cc
			@__kangxi_radical_base_strokes[radical_number] = nil
			return nil
		end

		# kTotalStrokes can exist in different Unihan source buckets; we only care about the value.
		prop = CharacterProperty.where(character_codepoint_id: cc.id, field: "kTotalStrokes").first
		val = prop&.value.to_s.strip
		strokes = val.split(/\s+/).first
		@__kangxi_radical_base_strokes[radical_number] = strokes&.to_i
	end

	def self.apostrophe_meaning(apos)
		case apos
		when "'"
			I18n.t("dictionary.field_lens.chinese_simplified_radical")
		when "''"
			I18n.t("dictionary.field_lens.non_chinese_simplified_radical")
		when "'''"
			I18n.t("dictionary.field_lens.second_non_chinese_simplified_radical")
		else
			I18n.t("dictionary.field_lens.radical_variant")
		end
	end
  
  # Internal order
  # Sort of deprecated?
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
	


# Pronunciation sections are defined in one central registry.
#
# The registry also understands namespaced bulk fields such as:
#   reading.wu.shanghai.ipa
# so adding a reviewed dataset does not require another FieldLens case branch.
def self.pronunciation_sections(props)
  PronunciationRegistry.pronunciation_sections(props)
end

	# These fields go unused; either because they're either superseded by better data or handled by something else. 
	HIDDEN_FIELDS = %w[
		bs2014_mc_detail
		kDefinition
		kSimplifiedVariant
		kTraditionalVariant
		kCompatibilityVariant
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
		shuowen_entry
		kRSAdobe_Japan1_6 # duplicate of kRSUnicode, only it is contributed by Adobe. This isn't very useful.
		jp_manyogana_for
		menggu_ziyun_needs_adjustment
		menggu_ziyun_gloss
		menggu_ziyun_reconstruction
		manju_hergen_source_chunk
		zhongyuan_yinyun_gloss
		zhongyuan_yinyun_notes
		guangyun_definition
		guangyun_payload_raw
		manju_hergen_final
		manju_hergen_initial
		manju_hergen_occurrence_count
		manju_hergen_page_number
		zhongyuan_yinyun_unt_phonemic
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
		return "Strokes & radicals" if field.start_with?("kRS") || field == "kTotalStrokes" || field == "shuowen_category" || field == "ids_difficult_component_lookup"
		return "Education notes" if field.match?("kGradeLevel") || field.match?("kKoreanEducationHanja") || field == "cjk_808_common"
		return "Education notes" if field == "context" 
		return "Pronunciation" if PronunciationRegistry.pronunciation_field?(field)
		return "Input" if %w[kCangjie kFourCornerCode kMainlandTelegraph kTaiwanTelegraph].include?(field)
		return "Encodings & mappings" if field.include?("Variant") || field.start_with?("kSemantic") || field.start_with?("kSimplified") || field.start_with?("cedict_simp") || field.start_with?("kTraditional")
		return "Dictionary indices" if field.include?("kPhonetic") || field.match?(/hanyu/i) || field.start_with?("kMorohashi") || field.include?("kCihai") || field.start_with?("kFenn") || field.match?("kCowles") || field.include?("DaeJaweon") || field.start_with?("kFennIndex") || field.start_with?("kGSR") || field.include?("KangXi") || field.match?("kLau") || field.match?("kMatthews") || field.match?("kMeyerWempe") || field.match?("kNelson") || field.start_with?("kSBGY") || field.match?("kSMSZD2003Index") || field.start_with?("kSMSZD2003Index") || field.start_with?("kHKGlyph") || field.match?("kKarlgren") || field.match?("guangyun_rhyme_number") || field.match?("guangyun_category") || field.match?("menggu_ziyun_category") || field.match?("menggu_ziyun_xiaoyun_key") || field.match?("menggu_ziyun_xiaoyun_number") || field == "menggu_ziyun_rhyme" || field == "zhongyuan_yinyun_initial" || field == "zhongyuan_yinyun_final" || field == "zhongyuan_yinyun_xiaoyun" || field == "zhongyuan_yinyun_category" || field == "zhongyuan_yinyun_xiaoyun_key"
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
	"ids_difficult_component_lookup" => "IDS hard-to-input component lookup",
	"kDefinition" => { i18n: "unihan_definition" },
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
	"kHanyuPinlu" => { i18n: "hanyu_frequency" },
	"laoguoyin" => { i18n: "old_national_pronunciation" },
    "kCangjie" => { i18n: "cangjie_input" },
    "kFourCornerCode" => { i18n: "four_corner_input" },
	"kKorean" => { i18n: "korean_yale" },
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
	"general_chinese" => { i18n: "general_chinese" },
	"bs2014_mc" => { i18n: "middle_chinese" },
	"bs2006_mc" => { i18n: "middle_chinese" },
	"bs2014_oc" => { i18n: "old_chinese" },
	"kTang" => { i18n: "middle_chinese_stimson" }, # T’ang Poetic Vocabulary by Hugh M. Stimson, Far Eastern Publications, Yale University 1976. Method unclear.
	"kangxi_gloss" => { i18n: "kangxi_explanation" },
	"kKoreanName" => { i18n: "official_korean_name_since" }, # 인명용 한자 (人名用漢字) - 1,800 glyph set used for educational purposes. Unihan says it is a year that corresponds to the list; 2015 or 2018. There have been updates in 2022 and 2024 but they do not have the data: Improve? 
	"kGradeLevel" => { i18n: "hong_kong_grade" },
	"cedict_def" => { i18n: "cedict_definition" },
	"cedict_simp" => { i18n: "cedict_simplified" },
	"kPhonetic" => { i18n: "phonetic_class" }, # Ten Thousand Characters: An Analytic Dictionary, by G. Hugh Casey, S.J. Hong Kong: Kelly and Walsh, 1980. https://analyticphysics.com/Language/Chinese%20Phonetic%20Groups.htm
	"kRSUnicode" => { i18n: "kangxi_radicals_strokes" },
	"shuowen_category" => {
	  han: "說文部首",
	  pinyin: true,
	  pinyin_chunks: [2, 2]
	},
	"cjk_808_common" => { i18n: "cjk_808_common" },
	"context" => { i18n: "context" },
	"jp_manyogana_hiragana_etym" => { i18n: "manyogana_hiragana_etymology" },
	"jp_manyogana_katakana_etym" => { i18n: "manyogana_katakana_etymology" },
	"jp_manyogana_mora_table" => { i18n: "manyogana_mora_table" },
	"jp_shakuon_kana" => { i18n: "shakuon_kana" },
	"jp_shakkun_kana" => { i18n: "shakkun_kana" },
	"jp_mora_romaji" => { i18n: "mora_romaji" },
	"jp_manyogana_reading" => { i18n: "manyogana_reading" },
	"menggu_ziyun_phags_pa" => { i18n: "menggu_ziyun_phags_pa" },
	"menggu_ziyun_reconstruction" => { i18n: "menggu_ziyun_reconstruction" },
	"menggu_ziyun_transcription" => { i18n: "menggu_ziyun_transcription" },
	"menggu_ziyun_qieyun_position" => { i18n: "qieyun_position" },
	"menggu_ziyun_tone" => { i18n: "menggu_ziyun_tone" },
	"menggu_ziyun_rhyme" => { i18n: "menggu_ziyun_rhyme" },
	"menggu_ziyun_gloss" => { i18n: "menggu_ziyun_gloss" },
	"menggu_ziyun_variant" => { i18n: "menggu_ziyun_variant" },
	"menggu_ziyun_notes" => { i18n: "menggu_ziyun_notes" },
	"menggu_ziyun_needs_adjustment" => { i18n: "menggu_ziyun_adjustment" },
	"menggu_ziyun_xiaoyun_number" => { i18n: "menggu_ziyun_xiaoyun_number" },
	"menggu_ziyun_xiaoyun_key" => { i18n: "menggu_ziyun_xiaoyun_key" },
	"menggu_ziyun_category" => { i18n: "menggu_ziyun_category" },
	"zhongyuan_yinyun_xiaoyun" => { i18n: "zhongyuan_yinyun_xiaoyun" },
	"zhongyuan_yinyun_initial" => { i18n: "zhongyuan_yinyun_initial" },
	"zhongyuan_yinyun_final" => { i18n: "zhongyuan_yinyun_final" },
	"zhongyuan_yinyun_tone" => { i18n: "zhongyuan_yinyun_tone" },
	"zhongyuan_yinyun_yang_naisi" => { i18n: "zhongyuan_yinyun_yang_naisi" },
	"zhongyuan_yinyun_ning_jifu" => { i18n: "zhongyuan_yinyun_ning_jifu" },
	"zhongyuan_yinyun_xue_fengsheng" => { i18n: "zhongyuan_yinyun_xue_fengsheng" },
	"zhongyuan_yinyun_unt_phonemic" => { i18n: "zhongyuan_yinyun_unt_phonemic" },
	"zhongyuan_yinyun_unt" => { i18n: "zhongyuan_yinyun_unt" },
	"zhongyuan_yinyun_gloss" => { i18n: "zhongyuan_yinyun_gloss" },
	"zhongyuan_yinyun_notes" => { i18n: "zhongyuan_yinyun_notes" },
	"zhongyuan_yinyun_category" => { i18n: "zhongyuan_yinyun_category" },
	"zhongyuan_yinyun_xiaoyun_key" => { i18n: "zhongyuan_yinyun_xiaoyun_key" },
	"manju_hergen_ipa" => { i18n: "manchu_1763_ipa" },
	"manju_hergen_latin" => { i18n: "manchu_1763_latin" },
	"manju_hergen_manchu" => { i18n: "manchu_1763_manchu" },
	"guangyun_fanqie" => { i18n: "guangyun_fanqie" },
	"guangyun_rhyme" => { i18n: "guangyun_rime" },
	"guangyun_tone" => { i18n: "guangyun_tone" },
}.freeze
	
	# and some automatic stuff in case
	def self.label_for(field)
		# Pronunciation labels live in the central registry so the dictionary,
		# ruby UI and importers all use the same wording.
		pronunciation_label = PronunciationRegistry.label_for_field(field)
		return pronunciation_label if pronunciation_label.present?

		# 1) Look up a "pretty label" rule for this field in PRETTY.
		# If PRETTY does not contain this field, v will be nil.
		v = PRETTY[field]

		# 2) If PRETTY stores a plain String for this field, just use it.
		# Example: "kKangxi" => "康熙 Kāngxī"
		return v if v.is_a?(String)

		# 3) If PRETTY stores a Hash for this field, we build the label from parts.
		if v.is_a?(Hash)
			if v[:i18n].present?
				return I18n.t("dictionary.field_lens.property_labels.#{v[:i18n]}")
			end

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
