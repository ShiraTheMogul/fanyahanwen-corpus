class CharactersController < ApplicationController
	# NOTE: This controller powers a page that can easily become DB-bound once the
	# character_properties table grows large (Unihan/Kangxi/Shuowen, etc.).
	# The helpers below are written to minimise round-trips and to keep common
	# lookups index-friendly.

	def index
		# If the user submitted the form, redirect to a clean URL like /characters/U+3400 or /characters/反
		if params[:query].present?
			q = params[:query].strip
			redirect_to character_path(q)
			return
		end

		# Otherwise Rails renders index.html.erb. The generic dictionary cards
		# make this page the single entrance to both normalized historical
		# dictionaries and the older specialist radical/component browsers.
		@dictionary_works = DictionaryWork.order(:title, :corpus_work_id).to_a
	end

	# Memoised CharacterCodepoint lookup by integer codepoint.
	# Pattern: use this when a request may call find_by(codepoint: X) multiple times.
	# Why: even with Rails query cache, this avoids extra object allocations.
	def cc_for_codepoint(cp)
		@cc_by_codepoint ||= {}
		return @cc_by_codepoint[cp] if @cc_by_codepoint.key?(cp)
		@cc_by_codepoint[cp] = CharacterCodepoint.find_by(codepoint: cp)
	end

  # --- CC-CEDICT helpers -------------------------------------------------
  #
  # DB stores CC-CEDICT mapping fields on the traditional row.
  # e.g.
  #   說 has cedict_simp = 说
  #   说 has *no* CC-CEDICT row at all
  #
  # So if the user visits /characters/说, we must "reverse lookup":
  #   find the row where cedict_simp == "说"  -> that row is the traditional entry (說).
  #
  # This method returns the traditional codepoint when CC-CEDICT can tell us one.
  # If CC-CEDICT has no idea, it returns nil.
  # Pull the CC-CEDICT mapping fields for a CharacterCodepoint row in ONE query.
  # Returns a Hash like {"cedict_trad"=>"說", "cedict_simp"=>"说"}
  def cedict_fields_for_character_id(character_codepoint_id)
    @cedict_fields_by_cc_id ||= {}
    return @cedict_fields_by_cc_id[character_codepoint_id] if @cedict_fields_by_cc_id.key?(character_codepoint_id)

    rows = CharacterProperty
      .where(character_codepoint_id: character_codepoint_id, source: "CC-CEDICT")
      .where(field: ["cedict_trad", "ccdict_trad", "cedict_simp", "ccdict_simp"])
      .pluck(:field, :value)

    # Keep the first value per field (stable enough for our use).
    out = {}
    rows.each do |fld, val|
      out[fld.to_s] ||= val
    end

    @cedict_fields_by_cc_id[character_codepoint_id] = out
  end

  def cedict_trad_codepoint_for(cp)
    cc = cc_for_codepoint(cp)
    return nil unless cc

    fields = cedict_fields_for_character_id(cc.id)

    # Case 1: Some datasets store a direct "cedict_trad" field.
    trad = fields["cedict_trad"].presence || fields["ccdict_trad"].presence
    return trad.ord if trad.present? && trad.length == 1

    # Case 2: If this row has cedict_simp, it is already the traditional entry.
    simp = fields["cedict_simp"].presence || fields["ccdict_simp"].presence
    return cp if simp.present? && simp.length == 1

    # Case 3: Reverse lookup.
    # Find the traditional entry that points to THIS character as its simplified form.
    trad_id = CharacterProperty
      .where(source: "CC-CEDICT", field: ["cedict_simp", "ccdict_simp"], value: cc.chr)
      .order(:id)
      .limit(1)
      .pick(:character_codepoint_id)

    return nil unless trad_id

    CharacterCodepoint.find_by(id: trad_id)&.codepoint
  end

  # Follow "base" links until stable (and don’t get stuck in loops).
  def resolve_base_codepoint(start_cp)
    seen = {}
    cp = start_cp

    loop do
      break if seen[cp]
      seen[cp] = true

      # 1) Prefer CC-CEDICT traditional when available (e.g., 说 -> 說).
      cedict_trad_cp = cedict_trad_codepoint_for(cp)
      if cedict_trad_cp.present? && cedict_trad_cp != cp
        cp = cedict_trad_cp
        next
      end

      # 2) Otherwise fall back to VariantMapping (variant -> base).
      vm = VariantMapping.find_by(variant_codepoint: cp)
      break unless vm&.base_codepoint.present?
      break if vm.base_codepoint == cp

      cp = vm.base_codepoint
    end

    cp
  end

  # Given any codepoint, return the CC-CEDICT "other side" if it exists.
  # Examples:
  #   說 -> 说
  #   说 -> 說
  def cedict_partner_codepoint(cp)
    cc = cc_for_codepoint(cp)
    return nil unless cc

    fields = cedict_fields_for_character_id(cc.id)

    # If THIS row has cedict_simp, we are already on the traditional entry.
    simp = fields["cedict_simp"].presence || fields["ccdict_simp"].presence
    return simp.ord if simp.present? && simp.length == 1 && simp != cc.chr

    # Otherwise, try to locate the traditional entry and return its codepoint.
    trad_cp = cedict_trad_codepoint_for(cp)
    return nil unless trad_cp.present? && trad_cp != cp

    trad_cp
  end

	# Decide which codepoint should be treated as the canonical character.
	#
	# 1) If CC-CEDICT says this char has a traditional form (cedict_trad), prefer that as base.
	# 2) Else, if VariantMapping says this char maps to a base_codepoint, use that.
	# 3) Else, the char is its own base.
	def canonical_codepoint_for(character)
	  # Start by assuming "this character is its own base"
	  base_cp = character.codepoint

	  # CC-CEDICT trad/simp mapping
	  #
	  # Find the first "cedict_trad" property for X character.
	  trad = CharacterProperty
			   .where(character_codepoint_id: character.id, source: "CC-CEDICT", field: "cedict_trad")
			   .limit(1)
			   .pluck(:value)
			   .first

	  # If we got a trad character AND it's a single char AND it's different, prefer it as base. This is probably the canonical character. 
	  if trad.present? && trad.length == 1 && trad != character.chr
		return trad.ord
	  end

	  # VariantMapping
	  vm = VariantMapping.find_by(variant_codepoint: character.codepoint)

	  # If mapping exists and doesn't point to itself, use that base.
	  if vm && vm.base_codepoint.present? && vm.base_codepoint != character.codepoint
		return vm.base_codepoint
	  end

	  # Fallback: itself
	  base_cp
	end

	def show
		raw = params[:id].to_s.strip

		# --- 1) Parse the URL param into an Integer codepoint ---
		# Accepts three input shapes:
		#   A) "U+8BF4"   (common Unicode notation)
		#   B) "8BF4"     (hex without the "U+")
		#   C) "说"        (a literal character)
		codepoint =
			if raw.match?(/\AU\+[0-9A-Fa-f]+\z/)
				raw.delete_prefix("U+").to_i(16)
			elsif raw.match?(/\A[0-9A-Fa-f]+\z/)
				raw.to_i(16)
			else
				raw.ord
			end

		# --- 2) Load the requested character row (or cleanly handle "not found") ---
		@character = CharacterCodepoint.find_by(codepoint: codepoint)
		if @character.nil?
			# These instance variables are what the view expects.
			@base_character = nil
			@variant_characters = []
			@variants = []
			@properties = []
			@grouped_properties = {}
			@cedict_defs = []
			@unihan_definition = nil
			@kangxi_text = nil
			@kangxi_rsunicode_display = nil
			@kangxi_rsunicode_tooltip = nil
			@kangxi_rsadobe_display = nil
			@kangxi_rsadobe_tooltip = nil
			@cp_by_id = {}
			return
		end

		current_cp = @character.codepoint

		# --- 3) Decide the canonical "base" codepoint ---
		# This is where we stop simplified characters (like 说) from self-looping.
		# resolve_base_codepoint:
		#   - prefers CC-CEDICT traditional mapping when available (说 -> 說)
		#   - otherwise follows VariantMapping (variant -> base)
		#   - avoids infinite loops
		base_cp = resolve_base_codepoint(current_cp)
		base_cp = current_cp if base_cp.nil? # defensive: shouldn't happen, but nil would crash below

		# Only show a "Base character" box if the base is truly different.
		@base_character =
			if base_cp != current_cp
				CharacterCodepoint.find_by(codepoint: base_cp)
			else
				nil
			end

		# --- 4) Collect variants to display (as clickable links) ---
		# A) Variants from VariantMapping that point to the base.
		# We keep BOTH the list of codepoints and a lookup of per-variant sources.
		# This matters because some variant families (e.g. Zetian Script) have a
		# meaningful source label that should be shown in the Variants section.
		# B) The CC-CEDICT partner, so we always show trad<->simp when it exists.
		partner_cp = cedict_partner_codepoint(base_cp)

		# Collect VariantMapping variants for any reasonable "base" candidate.
		# This matters because base_cp can drift due to other canonicalisation rules
		# (e.g. CC-CEDICT partner), but the user still expects Zetian/other families
		# to appear as variants on the page they're viewing.
		base_candidates = [base_cp, current_cp, partner_cp].compact.uniq
		variant_mapping_rows = VariantMapping.where(base_codepoint: base_candidates).pluck(:variant_codepoint, :source)
		variant_mapping_source_by_cp = {}
		variant_mapping_rows.each do |cp, src|
			# Keep first non-blank source per codepoint (stable enough for display).
			next if cp.nil?
			variant_mapping_source_by_cp[cp] ||= src
		end
		moe_variant_cps = variant_mapping_rows.map { |cp, _| cp }.compact
		variant_cps = moe_variant_cps.dup
		compat_variant_cps = []

		# Add the CC-CEDICT partner as a clickable variant link.
		variant_cps << partner_cp if partner_cp


		# B2) Unihan compatibility variants (legacy: sometimes stored as "U+25BAB").
		# These should behave like the rest of the variant links, not as a standalone property row.
		ids_for_compat = [@character&.id, @base_character&.id].compact.uniq
		if ids_for_compat.any?
			CharacterProperty
				.where(character_codepoint_id: ids_for_compat, field: "kCompatibilityVariant")
				.pluck(:value)
				.each do |raw|
					next if raw.blank?
					s = raw.to_s.strip
					# Prefer explicit U+XXXX tokens (can be multiple per value)
					s.scan(/U\+[0-9A-Fa-f]{4,6}/).each do |u|
						compat_variant_cps << u.delete_prefix("U+").to_i(16)
					end
					# Fallback: single-character values
					if s !~ /U\+[0-9A-Fa-f]{4,6}/ && s.length == 1
						compat_variant_cps << s.ord
					end
				end
		end

		# Merge Unihan compatibility variants (if any)
		variant_cps.concat(compat_variant_cps) if compat_variant_cps.any?

		# C) Clean up the list: remove nils, duplicates, and "do not list self" items.
		variant_cps = variant_cps.compact.uniq
		variant_cps -= [base_cp, current_cp]

		# D) Load variant rows for the view (only variants that exist in our DB).
		@variant_characters = CharacterCodepoint.where(codepoint: variant_cps).order(:codepoint)

		# NOTE: We intentionally delay building @variants until after we load @properties,
		# because we want to label variants (e.g. "Simplified variant") and annotate
		# whether the variant has its own definitions.
		@variants = []

		# --- 5) Load properties ---
		# Variant families can be huge, and most properties are character-specific (e.g. dict indices, radicals, strokes, readings). This is especially dangerous when the Taiwan MoE sometimes doesn't intend for variants to be absolute (sometimes they are semantically different, esp. historically like 王/壬). 
		# Overinheritance causes a really really long article that may not even be relevant.
		# The ONLY inheritance rule (for now) is the definition section as that actually matters:
		# - If the current character has no definitions at all, we may borrow definition
		# - Text from the canonical/base character.
		# - Never borrow non-definition metadata.
			
		# 19-1-26 - Fixed bug where overinheritance would occur.
		family_rows = [@character, @base_character, *@variant_characters].compact
		@cp_by_id = family_rows.index_by(&:id)

		definition_pairs = [
				["CC-CEDICT", "cedict_def"],
				["Unihan_Readings", "kDefinition"],
				["Kangxi", "kangxi_gloss"],
				["Shuowen Jiezi", "shuowen_entry"]
		]
		definition_pair_set = definition_pairs.to_h { |src, fld| [[src, fld], true] }
		is_definition_prop = lambda do |prop|
				definition_pair_set[[prop.source.to_s, prop.field.to_s]] == true
		end

		current_props =
				CharacterProperty
					.where(character_codepoint_id: @character.id)
					.order(:field, :source, :value)
					.to_a

			current_has_any_definition = current_props.any? { |p| is_definition_prop.call(p) && p.value.to_s.strip.present? }

			inherited_definition_props = []
			if !current_has_any_definition && @base_character.present?
				# Pull ONLY definition fields from the base character.
				# (Nothing else should leak across variants.)
				# I can maybe add stuff for this later...
				inherited_definition_props = CharacterProperty
					.where(character_codepoint_id: @base_character.id)
					.where(
						definition_pairs.map { |src, fld| "(source = ? AND field = ?)" }.join(" OR "),
						*definition_pairs.flatten
					)
					.order(:field, :source, :value)
					.to_a
			end

		@properties = current_props + inherited_definition_props

		# Tooltip support: Baxter & Sagart 2014 MC analysis info.
		# We keep these rows hidden in the main list, and attach them to the
		# plain MC line via a hoverable info icon.
		@bs2014_mc_tooltips = {}
		begin
			details = @properties.select { |p| p.source == "Baxter & Sagart, 2014" && p.field == "bs2014_mc_detail" }
			by_mc = Hash.new { |h, k| h[k] = [] }
			details.each do |p|
				mc = p.value.to_s.strip.split(/\s+/, 2).first
				next if mc.blank?
				by_mc[mc] << p.value.to_s.strip
			end
			@bs2014_mc_tooltips = by_mc.transform_values { |arr| arr.uniq.join("\n") }
		rescue StandardError
			@bs2014_mc_tooltips = {}
		end

		

		# --- 5b) Old National Pronunciation (老國音 / Laoguoyin) ---
		# This data is stored in laoguoyin_readings, not character_properties.
		# To make it participate in the normal FieldLens + Properties pipeline,
		# we project each exact-character reading row into an unsaved
		# CharacterProperty-like object. Pronunciations never inherit from variants.
		#
		# Field used in the UI: "laoguoyin"
		# Value shape (best-effort): "<latin> <zhuyin> /<ipa>/"
		if defined?(LaoguoyinReading)
			LaoguoyinReading
				.where(character_codepoint_id: @character.id)
				.order(:character_codepoint_id, :laoguoyin, :zhuyin, :ipa, :source)
				.each do |r|
					parts = []
					parts << r.laoguoyin.to_s.strip if r.laoguoyin.present?
					parts << r.zhuyin.to_s.strip if r.zhuyin.present?
					if r.ipa.present?
						ipa = r.ipa.to_s.strip
						parts << (ipa.start_with?("/") ? ipa : "/#{ipa}/")
					end
					val = parts.join(" ").strip
					next if val.blank?
					@properties << CharacterProperty.new(
						character_codepoint_id: r.character_codepoint_id,
						source: r.source.presence || "Old National Pronunciation",
						field: "laoguoyin",
						value: val
					)
				end
		end

		# Keep ordering stable after injecting virtual properties.
		@properties.sort_by! { |p| [p.field.to_s, p.source.to_s, p.value.to_s] }

		# Build a fast lookup for "give me the first row for (cid, source, field)".
		# Pattern: when you need to repeatedly fetch one value out of a big array,
		# build an index once, then do O(1) hash lookups.
		@first_prop_by_triplet = {}
		@properties.each do |p|
			key = [p.character_codepoint_id, p.source.to_s, p.field.to_s]
			@first_prop_by_triplet[key] ||= p
		end

		# Prefer current character's own definitions.
		# Only if the current character has NO definitions at all do we fall back to base.
		preferred_id_order =
			if current_has_any_definition
				[@character.id]
			else
				[@base_character&.id, @character.id].compact
			end

		# --- 6) Definition blocks (special sections on the page) ---
		# CC-CEDICT definitions can exist on multiple rows in the family.
		# We pick ONE "best" source row (usually the base), but we also record
		# where the definitions came from so the UI can say "inherited from X".
		# Variant-specific definition blocks need access to variant rows, but we do NOT
		# want to load *all* variant properties (indices, strokes, radicals, etc.).
		# So we query only definition fields here.
		definition_ids = ([@character.id, @base_character&.id].compact + @variant_characters.map(&:id)).uniq
		cedict_rows = CharacterProperty.where(character_codepoint_id: definition_ids, source: "CC-CEDICT", field: "cedict_def").to_a
		cedict_defs_by_id = cedict_rows.group_by(&:character_codepoint_id).transform_values do |rows|
			rows.map(&:value).uniq
		end

		# Normalise a "list of definitions" so we can compare them reliably.
		# Why we need this:
		# - one row may contain duplicate strings
		# - some sources may have trailing spaces
		# - we want to compare "variant definitions" vs "base definitions"
		normalise_defs = lambda do |arr|
			Array(arr)
				.map { |s| s.to_s.strip }
				.reject(&:blank?)
				.uniq
		end

		@cedict_defs = []
		@cedict_defs_from_id = nil
		preferred_id_order.each do |cid|
			defs = cedict_defs_by_id[cid]
			next unless defs.present?
			@cedict_defs = normalise_defs.call(defs)
			@cedict_defs_from_id = cid
			break
		end

		@cedict_defs_from = @cp_by_id[@cedict_defs_from_id]
		@cedict_defs_inherited = @cedict_defs_from_id.present? && @cedict_defs_from_id != @character.id

		# For single-value fields, we want both the value AND the row it came from.
		pick_first_with_source = lambda do |source:, field:|
			preferred_id_order.each do |cid|
				row = @first_prop_by_triplet[[cid, source.to_s, field.to_s]]
				return [row.value, cid] if row
			end
			[nil, nil]
		end

		@unihan_definition, @unihan_definition_from_id = pick_first_with_source.call(source: "Unihan_Readings", field: "kDefinition")
		@unihan_definition = @unihan_definition.to_s.strip.presence
		@unihan_definition_from = @cp_by_id[@unihan_definition_from_id]
		@unihan_definition_inherited = @unihan_definition_from_id.present? && @unihan_definition_from_id != @character.id

		@kangxi_text, @kangxi_text_from_id = pick_first_with_source.call(source: "Kangxi", field: "kangxi_gloss")
		# Fallback for older imports where the source may be missing.
		if @kangxi_text.blank?
			fallback_row = @properties.find { |p| p.field == "kangxi_gloss" }
			@kangxi_text = fallback_row&.value
			@kangxi_text_from_id = fallback_row&.character_codepoint_id
		end
		@kangxi_text_from = @cp_by_id[@kangxi_text_from_id]
		@kangxi_text_inherited = @kangxi_text_from_id.present? && @kangxi_text_from_id != @character.id
		# --- Guangyun (Siku) ---
		# Guangyun payloads can have multiple rows per character. We show them verbatim
		# in the character page's "廣韻" section, and also show the mapped rime category
		# when present (from the juan/categories importer).
		begin
			gy_payload_rows = @properties.select { |p| p.field == "guangyun_payload_raw" && p.value.to_s.strip.present? }
			# Prefer the source used by the payload rows; fall back to the common default.
			gy_source = gy_payload_rows.map { |p| p.source.to_s }.reject(&:blank?).first
			gy_source = "Guangyun (Siku)" if gy_source.blank?
			payloads = gy_payload_rows
				.select { |p| p.source.to_s == gy_source }
				.map { |p| p.value.to_s.strip }
				.reject(&:blank?)
				.uniq
			@guangyun_payload_raw = payloads.any? ? payloads.join("\n\n") : nil
			cats = @properties
				.select { |p| p.field == "guangyun_category" && p.value.to_s.strip.present? && (p.source.to_s == gy_source || p.source.to_s.blank?) }
				.map { |p| p.value.to_s.strip }
				.reject(&:blank?)
				.uniq
			@guangyun_category = cats.any? ? cats.join(" / ") : nil
		rescue StandardError
			@guangyun_payload_raw = nil
			@guangyun_category = nil
		end


		# --- 6a) Kangxi radical-stroke info (do NOT inherit across variants) ---
		# These fields are identifiers/index data for collation and glyph lookup,
		# and must stay specific to the current character.
		rsunicode_value = CharacterProperty
			.where(character_codepoint_id: @character.id, field: "kRSUnicode")
			.order(:id)
			.limit(1)
			.pick(:value)

		if rsunicode_value.present?
			display, tooltip = FieldLens.display_value_and_tooltip("kRSUnicode", rsunicode_value)
			@kangxi_rsunicode_display = display
			@kangxi_rsunicode_tooltip = tooltip
		else
			@kangxi_rsunicode_display = nil
			@kangxi_rsunicode_tooltip = nil
		end

		rsadobe_value = CharacterProperty
			.where(character_codepoint_id: @character.id, field: "kRSAdobe_Japan1_6")
			.order(:id)
			.limit(1)
			.pick(:value)

		if rsadobe_value.present?
			display, tooltip = FieldLens.display_value_and_tooltip("kRSAdobe_Japan1_6", rsadobe_value)
			@kangxi_rsadobe_display = display
			@kangxi_rsadobe_tooltip = tooltip
		else
			@kangxi_rsadobe_display = nil
			@kangxi_rsadobe_tooltip = nil
		end

		@shuowen_entry, @shuowen_entry_from_id = pick_first_with_source.call(source: "Shuowen Jiezi", field: "shuowen_entry")
		@shuowen_entry = @shuowen_entry.to_s.strip.presence
		@shuowen_entry_from = @cp_by_id[@shuowen_entry_from_id]
		@shuowen_entry_inherited = @shuowen_entry_from_id.present? && @shuowen_entry_from_id != @character.id

		@shuowen_category, @shuowen_category_from_id = pick_first_with_source.call(source: "Shuowen Jiezi", field: "shuowen_category")
		@shuowen_category = @shuowen_category.to_s.strip.presence
		@shuowen_category_from = @cp_by_id[@shuowen_category_from_id]
		@shuowen_category_inherited = @shuowen_category_from_id.present? && @shuowen_category_from_id != @character.id

		# --- 6b) Build "variant-specific definition blocks" ---
		# File: app/controllers/characters_controller.rb
		# Purpose: mark variants that have dictionary text which is:
		#   (a) directly attached to the variant row, and
		#   (b) different from the canonical/base text.
		#
		# The view layer (app/views/characters/show.html.erb) uses these blocks to
		# render a dedicated "variant-specific" section.
			unihan_by_id = CharacterProperty
				.where(character_codepoint_id: definition_ids, source: "Unihan_Readings", field: "kDefinition")
				.to_a
				.group_by(&:character_codepoint_id)
				.transform_values { |rows| rows.map { |r| r.value.to_s.strip }.find(&:present?) }

		# Prefer the explicit Kangxi source when present.
		# This keeps the query index-friendly (character_codepoint_id + source + field).
		kangxi_by_id = CharacterProperty
			.where(character_codepoint_id: definition_ids, source: "Kangxi", field: "kangxi_gloss")
			.to_a
			.group_by(&:character_codepoint_id)
			.transform_values { |rows| rows.map { |r| r.value.to_s.strip }.find(&:present?) }

		# Back-compat: older imports may have kangxi_gloss rows without a source.
		missing_kangxi_ids = definition_ids - kangxi_by_id.keys
		if missing_kangxi_ids.any?
			fallback = CharacterProperty
				.where(character_codepoint_id: missing_kangxi_ids, field: "kangxi_gloss")
				.to_a
				.group_by(&:character_codepoint_id)
				.transform_values { |rows| rows.map { |r| r.value.to_s.strip }.find(&:present?) }
			kangxi_by_id.merge!(fallback)
		end

		primary_cedict_defs = normalise_defs.call(@cedict_defs)
		primary_unihan_def = @unihan_definition.to_s.strip
		primary_kangxi_text = @kangxi_text.to_s.strip

		@variant_definition_blocks = []
		@variant_characters.each do |cc|
			v_cedict = normalise_defs.call(cedict_defs_by_id[cc.id])
			v_unihan = unihan_by_id[cc.id].to_s.strip
			v_kangxi = kangxi_by_id[cc.id].to_s.strip

			cedict_unique = v_cedict.present? && v_cedict != primary_cedict_defs
			unihan_unique = v_unihan.present? && v_unihan != primary_unihan_def
			kangxi_unique = v_kangxi.present? && v_kangxi != primary_kangxi_text

			next unless cedict_unique || unihan_unique || kangxi_unique

			@variant_definition_blocks << {
				character: cc,
				cedict_defs: (cedict_unique ? v_cedict : nil),
				unihan_definition: (unihan_unique ? v_unihan : nil),
				kangxi_text: (kangxi_unique ? v_kangxi : nil)
			}
		end

		# --- 7) Build the variants list with labels + "has its own entry" flags ---
		# Determine whether the canonical/base row is "traditional" in CC-CEDICT terms.
		base_row = @base_character || @character
		base_is_cedict_trad = CharacterProperty
			.where(character_codepoint_id: base_row.id, source: "CC-CEDICT", field: ["cedict_simp", "ccdict_simp"])
			.exists?

		@variants = @variant_characters.map do |cc|
			helper_hex = cc.codepoint.to_s(16).upcase
			kind = if partner_cp.present? && cc.codepoint == partner_cp
				base_is_cedict_trad ? "Simplified variant" : "Traditional variant"
			else
				"Variant"
			end

			# "Has its own definition" means: we will show a variant-specific definition
			# block under the Definitions section.
			has_variant_specific_defs = @variant_definition_blocks.any? { |blk| blk[:character].id == cc.id }

			# Source label priority:
			# 1) If this variant came from VariantMapping and has a meaningful source
			#    (e.g. "Zetian Script (則天文字)"), show that.
			# 2) Otherwise, preserve the existing buckets.
			source =
				if variant_mapping_source_by_cp[cc.codepoint].present?
					variant_mapping_source_by_cp[cc.codepoint]
				elsif moe_variant_cps.include?(cc.codepoint)
					"MOE 異典收字清單"
				elsif partner_cp.present? && cc.codepoint == partner_cp
					"CC-CEDICT"
				elsif compat_variant_cps.include?(cc.codepoint)
					"Unihan_Variants"
				else
					"VariantMapping"
				end

{
	codepoint: cc.codepoint,
	hex: helper_hex,
	glyph: cc.chr,
	label: "#{cc.chr} (U+#{helper_hex})",
	kind: kind,
	source: source,
	has_own_entry: has_variant_specific_defs
}
		end

		# --- Everything else goes through FieldLens grouping/sorting ---
		properties_for_generic_list =
		  @properties.reject { |p| FieldLens.hidden_prop?(p) }  # hidden_prop? expects ONE arg: the prop

		grouped =
		  properties_for_generic_list.group_by { |p| FieldLens.group_for(p.field) }

		# Pronunciation properties get duplicated because we load the *whole family*
		# (current character + base + variants). That's intentional for variants/definitions,
		# but for readings it's noisy. So: collapse identical entries (same field/source/value).
		if grouped["Pronunciation"].present?
			grouped["Pronunciation"] =
				grouped["Pronunciation"].uniq do |p|
					[p.field, p.source.to_s, p.value.to_s.strip]
				end
		end

		@grouped_properties = FieldLens.sort_grouped(grouped)
	end
	

	# Tooltip preview (lightweight JSON)
	# GET /characters/:id/preview
	def preview
		raw = params[:id].to_s.strip
		codepoint =
			if raw.match?(/\AU\+[0-9A-Fa-f]+\z/)
				raw.delete_prefix("U+").to_i(16)
			elsif raw.match?(/\A[0-9A-Fa-f]+\z/)
				raw.to_i(16)
			else
				raw.ord
			end

		cc = CharacterCodepoint.find_by(codepoint: codepoint)
		return render json: { found: false }, status: :not_found unless cc

		props = CharacterProperty.where(character_codepoint_id: cc.id).to_a

		cedict_defs = props
			.select { |p| p.source == "CC-CEDICT" && p.field == "cedict_def" }
			.map(&:value)
			.map { |s| s.to_s.strip }
			.reject(&:blank?)
			.uniq

		unihan_def = props.find { |p| p.source == "Unihan_Readings" && p.field == "kDefinition" }&.value
		kangxi_text = props.find { |p| p.source == "Kangxi" && p.field == "kangxi_gloss" }&.value

		# Ruby/pronunciation (best-effort; mirrors the "ruby" headword choice)
		# Tooltip pronunciation should NOT depend on whether ruby is enabled on the page.
		# Still report ruby_enabled for UI state, but always compute a best-effort reading. If all else fails, Mandarin is the fallback. 
		ruby_enabled = (session[:ruby_enabled] == true || session[:ruby_enabled].to_s == "1" || session[:ruby_enabled].to_s == "true")
		ruby_source = (session[:ruby_source].presence || :mandarin).to_s.strip.downcase.tr(" ", "_").to_sym

		ruby_entry = PronunciationRegistry.ruby_source(ruby_source)
		ruby_reading = nil

		if ruby_entry&.dig(:special) == :laoguoyin
			reading = LaoguoyinReading.find_by(character_codepoint_id: cc.id)
			if reading
				parts = []
				parts << reading.laoguoyin.to_s.strip if reading.laoguoyin.present?
				parts << reading.zhuyin.to_s.strip if reading.zhuyin.present?
				if reading.ipa.present?
					ipa = reading.ipa.to_s.strip
					parts << (ipa.start_with?("/") ? ipa : "/#{ipa}/")
				end
				raw = parts.join(" ")
				scheme = (session[:laoguoyin_scheme].presence || :original).to_sym
				ruby_reading = helpers.format_laoguoyin_value(raw, scheme: scheme) if raw.present?
			end
		elsif ruby_entry
			candidates = props.select do |prop|
				prop.field == ruby_entry[:field] &&
					(ruby_entry[:sources].empty? || ruby_entry[:sources].include?(prop.source.to_s))
			end
			source_rank = ruby_entry[:sources].each_with_index.to_h
			raw_reading = candidates.min_by do |prop|
				[source_rank.fetch(prop.source.to_s, 999), prop.value.to_s]
			end&.value.to_s
			tokens = raw_reading.strip.split(/\s+/).map(&:strip).reject(&:blank?)
			desired = session[:ruby_token].to_s.strip
			ruby_reading = (desired.present? && tokens.include?(desired)) ? desired : tokens.first
		end

		render json: {
			found: true,
			chr: cc.chr,
			codepoint: cc.codepoint,
			uplus: format("U+%04X", cc.codepoint),
			block: UnicodeRanges.han_block_label(cc.codepoint),
			ruby: {
				enabled: ruby_enabled,
				source: ruby_source,
				reading: ruby_reading
			},
			dictionaries: {
				cedict: cedict_defs,
				unihan: unihan_def,
				kangxi: kangxi_text
			}
		}
	end

end # eof