class CharactersController < ApplicationController
	def index
		# If the user submitted the form, redirect to a clean URL like /characters/U+3400 or /characters/反
		if params[:query].present?
			q = params[:query].strip
			redirect_to character_path(q)
			return
		end

		# Otherwise Rails renders index.html.erb
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
  def cedict_trad_codepoint_for(cp)
    cc = CharacterCodepoint.find_by(codepoint: cp)
    return nil unless cc

    # Case 1: Some datasets store a direct "cedict_trad" field.
    trad = CharacterProperty
      .where(character_codepoint_id: cc.id, source: "CC-CEDICT", field: ["cedict_trad", "ccdict_trad"])
      .limit(1)
      .pluck(:value)
      .first

    if trad.present? && trad.length == 1
      return trad.ord
    end

    # Case 2: If this row has cedict_simp, it is already the traditional entry.
    simp = CharacterProperty
      .where(character_codepoint_id: cc.id, source: "CC-CEDICT", field: ["cedict_simp", "ccdict_simp"])
      .limit(1)
      .pluck(:value)
      .first

    return cp if simp.present? && simp.length == 1

    # Case 3: Reverse lookup.
    # Find the traditional entry that points to THIS character as its simplified form.
    trad_id = CharacterProperty
      .where(source: "CC-CEDICT", field: ["cedict_simp", "ccdict_simp"], value: cc.chr)
      .limit(1)
      .pluck(:character_codepoint_id)
      .first

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
    cc = CharacterCodepoint.find_by(codepoint: cp)
    return nil unless cc

    # If THIS row has cedict_simp, we are already on the traditional entry.
    simp = CharacterProperty
      .where(character_codepoint_id: cc.id, source: "CC-CEDICT", field: ["cedict_simp", "ccdict_simp"])
      .limit(1)
      .pluck(:value)
      .first

    if simp.present? && simp.length == 1 && simp != cc.chr
      return simp.ord
    end

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
		variant_cps = VariantMapping.where(base_codepoint: base_cp).pluck(:variant_codepoint)

		# B) The CC-CEDICT partner, so we always show trad<->simp when it exists.
		partner_cp = cedict_partner_codepoint(base_cp)
		variant_cps << partner_cp if partner_cp

		# C) Clean up the list: remove nils, duplicates, and "do not list self" items.
		variant_cps = variant_cps.compact.uniq
		variant_cps -= [base_cp, current_cp]

		# D) Load variant rows for the view (only variants that exist in our DB).
		@variant_characters = CharacterCodepoint.where(codepoint: variant_cps).order(:codepoint)

		# NOTE: We intentionally delay building @variants until after we load @properties,
		# because we want to label variants (e.g. "Simplified variant") and annotate
		# whether the variant has its own definitions.
		@variants = []

		# --- 5) Load properties for current + base + variants ---
		# We pull properties for the whole "family" so we can:
		#   - show inherited definitions
		#   - show variants that have their own readings
		family_rows = [@character, @base_character, *@variant_characters].compact
		family_ids = family_rows.map(&:id).uniq

		@cp_by_id = family_rows.index_by(&:id)

		@properties =
			CharacterProperty
				.where(character_codepoint_id: family_ids)
				.order(:field, :source, :value)
				.to_a

		

		# --- 5b) Old National Pronunciation (老國音 / Laoguoyin) ---
		# This data is stored in laoguoyin_readings, not character_properties.
		# To make it participate in the normal FieldLens + Properties pipeline,
		# we project each reading row into an *unsaved* CharacterProperty-like object.
		#
		# Field used in the UI: "laoguoyin"
		# Value shape (best-effort): "<latin> <zhuyin> /<ipa>/"
		if defined?(LaoguoyinReading)
			LaoguoyinReading
				.where(character_codepoint_id: family_ids)
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

# Prefer base -> current -> variants when we have to pick ONE "best" source.
		preferred_id_order = [@base_character&.id, @character.id] + @variant_characters.map(&:id)
		preferred_id_order.compact!

		# --- 6) Definition blocks (special sections on the page) ---
		# CC-CEDICT definitions can exist on multiple rows in the family.
		# We pick ONE "best" source row (usually the base), but we also record
		# where the definitions came from so the UI can say "inherited from X".
		cedict_rows = @properties.select { |p| p.source == "CC-CEDICT" && p.field == "cedict_def" }
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
				row = @properties.find { |p| p.character_codepoint_id == cid && p.source == source && p.field == field }
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

		# --- 6b) Build "variant-specific definition blocks" ---
		# File: app/controllers/characters_controller.rb
		# Purpose: mark variants that have dictionary text which is:
		#   (a) directly attached to the variant row, and
		#   (b) different from the canonical/base text.
		#
		# The view layer (app/views/characters/show.html.erb) uses these blocks to
		# render a dedicated "variant-specific" section.
		unihan_by_id = @properties
			.select { |p| p.source == "Unihan_Readings" && p.field == "kDefinition" }
			.group_by(&:character_codepoint_id)
			.transform_values { |rows| rows.map { |r| r.value.to_s.strip }.find(&:present?) }

		kangxi_by_id = @properties
			.select { |p| p.field == "kangxi_gloss" }
			.group_by(&:character_codepoint_id)
			.transform_values { |rows| rows.map { |r| r.value.to_s.strip }.find(&:present?) }

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

			{
				codepoint: cc.codepoint,
				label: "#{cc.chr} (U+#{helper_hex})",
				kind: kind,
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

		field_name =
			case ruby_source
			when :mandarin then "kMandarin"
			when :cantonese then "kCantonese"
			when :japanese then "kJapanese"
			when :japanese_kana then "kJapanese"
			when :japanese_on then "kJapaneseOn"
			when :japanese_kun then "kJapaneseKun"
			when :korean_yale then "kKorean"
			when :korean_hangul then "kHangul"
			when :vietnamese then "kVietnamese"
			when :zhuang then "kZhuang"
			when :fanqie then "kFanqie"
			when :tang then "kTang"
			else
				nil
			end

		ruby_reading = nil
		if field_name
			raw_reading = props.find { |p| ["Unihan_Readings", "Unihan"].include?(p.source) && p.field == field_name }&.value.to_s
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
