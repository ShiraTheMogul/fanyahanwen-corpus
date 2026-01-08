# frozen_string_literal: true

# Import Baxter & Sagart 2014 (OC + MC) and Baxter 2006 (MC) PDFs into
# character_properties.
#
# Design goals:
# - No hardcoded URLs in the DB. Only human citation strings in `source`.
# - Idempotent re-runs (unique index on [character, source, field, value]).
# - Keep MC analysis info (parentheses) available via tooltip, but keep ruby
#   text clean by storing the plain MC syllable separately.
# - Use Unihan kGSR to map Baxter 2006 entries to Unicode when possible.

require "pdf/reader"

module Importers
  class BaxterSagartImporter
    # Example tail token: "U+533F"
    UPLUS_RE = /(U\+[0-9A-F]{4,6})\z/

    # GSR codes look like "0777l", "1190a", etc.
    GSR_RE = /\A\d{4}[a-z-](?:')?\z/i

    # Layout-extracted BS2014 rows look like:
    #   0777l    匿    nì     nrik     (nr- + -ik D)    *nr[əә]k ... U+533F
    #
    # We only care about:
    #   GSR, Hanzi, MC syllable, optional MC analysis (parentheses), OC token, Unicode.
    BS2014_ROW_RE = /
      \A(?<gsr>\S+)\s+
      (?<zi>\S+)\s+
      (?<py>\S+)\s+
      (?<mc>\S+)
      (?:\s+(?<mc_detail>\([^)]*\)))?
      \s+(?<oc>\*\S+)
      .*?
      (?<uplus>U\+[0-9A-F]{4,6})\z
    /x

    # --- Normalisation -------------------------------------------------
    # Some PDFs (or extraction layers) yield doubled vowel glyph sequences.
    # The common observed bug: "əә" appears where only "ә" was intended.
    # We keep the overall string intact and just collapse the known artifact.
    def self.normalize_bs2014_oc(oc)
      return oc if oc.blank?

      s = oc.to_s
      s = s.gsub("əә", "ә").gsub("әə", "ә")
      s
    end

    # --- Mapping helpers ----------------------------------------------
    # Build GSR -> Unicode codepoint mapping from Unihan's kGSR.
    #
    # Notes:
    # - kGSR values can contain multiple tokens.
    # - Some GSR tokens can be ambiguous (map to multiple characters).
    #   For safety we DROP ambiguous tokens from the map.
    def self.build_gsr_map_from_unihan(verbose: false)
      map = {}
      ambiguous = {}
      seen = 0

      CharacterProperty
        .where(field: "kGSR")
        .includes(:character_codepoint)
        .find_each do |prop|
          seen += 1
          cc = prop.character_codepoint
          next unless cc&.codepoint

          prop.value.to_s.split(/\s+/).each do |tok|
            tok = tok.strip
            next if tok.empty?
            next unless tok.match?(GSR_RE)

            # If this token is already known ambiguous, skip.
            next if ambiguous[tok]

            existing = map[tok]
            if existing && existing != cc.codepoint
              # Ambiguous mapping. Remove and mark ambiguous.
              map.delete(tok)
              ambiguous[tok] = true
              next
            end

            map[tok] ||= cc.codepoint
          end
        end

      puts "[GSR] built from Unihan: map=#{map.size} ambiguous=#{ambiguous.size} scanned_props=#{seen}" if verbose
      map
    end

    # Merge two maps, preferring existing values. (We never overwrite.)
    def self.merge_gsr_maps(primary, secondary)
      out = primary.dup
      secondary.each do |k, v|
        out[k] ||= v
      end
      out
    end

    # --- Importers -----------------------------------------------------
    # Import Baxter & Sagart 2014 PDF (OC + MC). Returns GSR -> Unicode map.
    #
    # Stored fields:
    # - bs2014_mc         : plain MC syllable (ruby-safe)
    # - bs2014_mc_detail  : MC syllable + parenthetical analysis, for tooltip
    # - bs2014_oc         : OC reconstruction token (normalized)
    def self.import_bs2014_pdf(
      path:,
      source: "Baxter & Sagart, 2014",
      field_oc: "bs2014_oc",
      field_mc: "bs2014_mc",
      field_mc_detail: "bs2014_mc_detail",
      verbose: true
    )
      full_path = Rails.root.join(path).to_s
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      reader = PDF::Reader.new(full_path)
      gsr_to_codepoint = {}

      imported = 0
      skipped = 0

      ActiveRecord::Base.transaction do
        reader.pages.each_with_index do |page, pi|
          page.text.to_s.each_line do |line|
            line = line.strip
            next if line.empty?
            next unless line.match?(UPLUS_RE)

            m = BS2014_ROW_RE.match(line)
            unless m
              skipped += 1
              next
            end

            gsr = m[:gsr]
            uplus = m[:uplus]
            codepoint = uplus.delete_prefix("U+").to_i(16)

            mc = m[:mc].to_s.strip
            oc = normalize_bs2014_oc(m[:oc].to_s.strip)
            mc_detail = m[:mc_detail].to_s.strip

            # In rare cases, extraction can produce blanks. Skip those rows.
            if gsr.blank? || mc.blank? || oc.blank?
              skipped += 1
              next
            end

            chr = codepoint.chr(Encoding::UTF_8)
            cc = CharacterCodepoint.find_or_create_by!(codepoint: codepoint) { |row| row.chr = chr }

            CharacterProperty.find_or_create_by!(
              character_codepoint_id: cc.id,
              source: source,
              field: field_mc,
              value: mc
            )

            # Store MC analysis info (tooltip).
            if mc_detail.present?
              CharacterProperty.find_or_create_by!(
                character_codepoint_id: cc.id,
                source: source,
                field: field_mc_detail,
                value: "#{mc} #{mc_detail}".strip
              )
            end

            CharacterProperty.find_or_create_by!(
              character_codepoint_id: cc.id,
              source: source,
              field: field_oc,
              value: oc
            )

            gsr_to_codepoint[gsr] ||= codepoint
            imported += 1
          end

          if verbose && ((pi + 1) % 10).zero?
            puts "[BS2014] page=#{pi + 1}/#{reader.pages.size} imported=#{imported} skipped=#{skipped}" 
          end
        end
      end

      puts "[BS2014] DONE imported=#{imported} skipped=#{skipped} gsr_map=#{gsr_to_codepoint.size}" if verbose
      gsr_to_codepoint
    end

    # Import Baxter 2006 PDF (MC only).
    #
    # Mapping strategy:
    # - Use provided gsr_to_codepoint map if given.
    # - Also build a Unihan-backed GSR map (kGSR) and merge it in.
    # - Drop ambiguous Unihan mappings.
    def self.import_baxter2006_mc_pdf(
      path:,
      gsr_to_codepoint: nil,
      source: "Baxter (with Sagart), 2006",
      field_mc: "bs2006_mc",
      verbose: true
    )
      full_path = Rails.root.join(path).to_s
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      # Build / merge mapping.
      map = gsr_to_codepoint || {}
      unihan_map = build_gsr_map_from_unihan(verbose: verbose)
      map = merge_gsr_maps(map, unihan_map)

      reader = PDF::Reader.new(full_path)

      imported = 0
      skipped = 0
      unmatched = 0

      ActiveRecord::Base.transaction do
        reader.pages.each_with_index do |page, pi|
          page.text.to_s.each_line do |line|
            line = line.strip
            next if line.empty?

            # Header-ish lines commonly appear in extraction.
            next if line.start_with?("Bill Baxter")
            next if line.start_with?("www.")

            parts = line.split(/\s+/)

            # Find the GSR token anywhere in the row.
            gsr_index = parts.index { |t| t.match?(GSR_RE) }
            next unless gsr_index && gsr_index >= 2

            gsr = parts[gsr_index]
            mc = parts[gsr_index - 1]

            cp = map[gsr]
            unless cp
              unmatched += 1
              next
            end

            cc = CharacterCodepoint.find_by(codepoint: cp)
            unless cc
              skipped += 1
              next
            end

            CharacterProperty.find_or_create_by!(
              character_codepoint_id: cc.id,
              source: source,
              field: field_mc,
              value: mc
            )

            imported += 1
          end

          if verbose && ((pi + 1) % 10).zero?
            puts "[Baxter2006] page=#{pi + 1}/#{reader.pages.size} imported=#{imported} unmatched=#{unmatched} skipped=#{skipped}"
          end
        end
      end

      puts "[Baxter2006] DONE imported=#{imported} unmatched=#{unmatched} skipped=#{skipped}" if verbose
      { imported: imported, unmatched: unmatched, skipped: skipped }
    end
  end
end
