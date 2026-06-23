# frozen_string_literal: true

require "csv"
require "roo"

module Importers
  class SupplementalScriptsImporter
    def import_slavonic_csv!(path, source: "slavonic_wiki")
      each_csv_row(path) do |row|
        glyph = normalize_glyph(row["char"])
        next if glyph.nil?

        cc = ensure_codepoint!(glyph)

        mandarin = normalize_cell(row["mandarin"])
        upsert_property!(cc, field: "kMandarin", source: source, value: mandarin) if present?(mandarin)

        ipa = normalize_cell(row["ipa"])
        latin = normalize_cell(row["latin"])
        cyr = normalize_cell(row["cyrillic"])

        context_lines = []
        context_lines << "IPA: #{ipa}" if present?(ipa)
        context_lines << "Russian: #{cyr}" if present?(cyr)
        context_lines << "Latin: #{latin}" if present?(latin)

        upsert_property!(cc, field: "context", source: source, value: context_lines.join("\n")) if context_lines.any?
      end
    end

    def import_zetian_csv!(path, mapping_source: "Zetian Script (則天文字)", prop_source: "zetian")
      each_csv_row(path) do |row|
        base_glyph = normalize_glyph(row["base"])
        var_glyph = normalize_glyph(row["wu-var"])
        next if base_glyph.nil? || var_glyph.nil?

        ensure_codepoint!(base_glyph)
        ensure_codepoint!(var_glyph)

        vm = VariantMapping.find_or_initialize_by(variant_codepoint: var_glyph.ord)
        vm.base_codepoint = base_glyph.ord
        vm.source = mapping_source
        vm.save!

        note = "Character imposed by Empress Wu Zetian 武則天 of Zhou 武周 (Reigned 16 October 690 – 21 February 705)"
        src = normalize_cell(row["source"])
        ctx = present?(src) ? "#{note}\n#{src}" : note

        cc_var = CharacterCodepoint.find_by!(codepoint: var_glyph.ord)
        upsert_property!(cc_var, field: "context", source: prop_source, value: ctx)
      end
    end

    def import_manyogana_etym_xlsx!(path, field:, source:)
      sheet = Roo::Spreadsheet.open(path).sheet(0)
      last_row = sheet.last_row
      last_col = sheet.last_column

      r = 2
      while r <= last_row
        row_key = normalize_cell(sheet.cell(r, 1))
        kana_row_key = normalize_cell(sheet.cell(r + 1, 1))
        break if row_key.nil?

        if kana_row_key.nil?
          (2..last_col).each do |c|
            manyo = normalize_cell(sheet.cell(r, c))
            kana = normalize_cell(sheet.cell(r + 1, c))
            next unless present?(manyo) && present?(kana)

            cc = ensure_codepoint!(kana)
            upsert_property!(cc, field: field, source: source, value: manyo)
          end
          r += 2
        else
          r += 1
        end
      end
    end

    # Import mora table and also write jp_mora_romaji onto the kana glyph.
    # We compute romaji from (column header consonant) + (row vowel).
    def import_manyogana_mora_table_xlsx!(path, kana_lookup_xlsx:, field: "jp_manyogana_mora_table", source: "manyogana_wiki")
      mora_sheet = Roo::Spreadsheet.open(path).sheet(0)
      lookup_sheet = Roo::Spreadsheet.open(kana_lookup_xlsx).sheet(0)

      mora_last_row = mora_sheet.last_row
      mora_last_col = mora_sheet.last_column
      lookup_last_row = lookup_sheet.last_row
      lookup_last_col = lookup_sheet.last_column

      # Column headers in mora table (row 1): consonant groups (K, S, T, N, H, M, Y, R, W, etc.)
      consonant_headers = {}
      (2..mora_last_col).each do |c|
        consonant_headers[c] = normalize_cell(mora_sheet.cell(1, c))
      end

      # Lookup rows: vowel label -> row index in lookup sheet
      lookup_rows = {}
      (2..lookup_last_row).each do |r|
        key = normalize_cell(lookup_sheet.cell(r, 1))
        next unless present?(key)
        lookup_rows[key] ||= r
      end

      (2..mora_last_row).each do |r|
        raw_key = normalize_cell(mora_sheet.cell(r, 1))
        next unless present?(raw_key)

        vowel = raw_key.to_s[/\A[a-z]+/]
        next unless present?(vowel)

        lookup_r = lookup_rows[vowel]
        next unless lookup_r
        kana_r = lookup_r + 1

        (2..mora_last_col).each do |c|
          manyo = normalize_cell(mora_sheet.cell(r, c))
          kana = normalize_cell(lookup_sheet.cell(kana_r, c))
          next unless present?(manyo) && present?(kana)

          cc = ensure_codepoint!(kana)
          upsert_property!(cc, field: field, source: source, value: manyo)

          consonant = consonant_headers[c]
          romaji = build_romaji(consonant, vowel)
          upsert_property!(cc, field: "jp_mora_romaji", source: source, value: romaji) if present?(romaji)
        end
      end
    end

    # Build reverse mapping from existing mora table properties:
    # For each kana that has jp_manyogana_mora_table, assign each manyogana kanji:
    #   jp_manyogana_reading = "#{romaji} #{kana}"
    def build_manyogana_reverse_from_mora_table!(mora_table_field: "jp_manyogana_mora_table", source: "manyogana_wiki")
      # Pull kana-side rows
      kana_props = CharacterProperty.where(field: mora_table_field).includes(:character_codepoint)

      kana_props.find_each do |kp|
        kana_cc = kp.character_codepoint
        kana = kana_cc.chr

        romaji = CharacterProperty.where(character_codepoint_id: kana_cc.id, field: "jp_mora_romaji").pluck(:value).first
        label = romaji ? "#{romaji} #{kana}" : kana

        kp.value.to_s.each_grapheme_cluster do |kan|
          next if kan.strip.empty?
          cc = ensure_codepoint!(kan)
          upsert_property!(cc, field: "jp_manyogana_reading", source: source, value: label)
        end
      end
    end

    def import_kana_borrowing_csv!(path, field:, source:)
      each_csv_row(path) do |row|
        morae = normalize_cell(row["Morae"])
        next unless present?(morae)

        row.headers.each do |h|
          next if h == "Morae"
          cell = normalize_cell(row[h])
          next unless present?(cell)

          parse_kana_borrowing_cell(cell).each do |kanji_token, kana_reading|
            next unless present?(kanji_token) && present?(kana_reading)
            first_char = kanji_token[0]
            cc = ensure_codepoint!(first_char)
            value = "#{kanji_token} → #{kana_reading} (morae=#{morae})"
            upsert_property!(cc, field: field, source: source, value: value)
          end
        end
      end
    end

    # ---- helpers ----

    def each_csv_row(path, &block)
      CSV.foreach(path, headers: true, encoding: "bom|utf-8") { |row| yield row }
    end

    def ensure_codepoint!(glyph)
      g = normalize_glyph(glyph)
      raise ArgumentError, "Expected a single glyph, got: #{glyph.inspect}" if g.nil?

      CharacterCodepoint.find_or_create_by!(codepoint: g.ord) { |cc| cc.chr = g }
    end

    def upsert_property!(cc, field:, source:, value:)
      v = normalize_cell(value)
      return if v.nil?

      prop = CharacterProperty.where(character_codepoint_id: cc.id, source: source, field: field).first
      if prop
        prop.value = v
        prop.save! if prop.changed?
      else
        CharacterProperty.create!(character_codepoint_id: cc.id, field: field, source: source, value: v)
      end
    rescue ActiveRecord::RecordNotUnique
      true
    end

    def parse_kana_borrowing_cell(cell)
      parts = cell.to_s.split(/[,，]/).map(&:strip)
      parts = parts.flat_map { |p| p.split(/[\s\u00A0]{2,}/) }.map(&:strip)
      parts.reject!(&:empty?)

      pairs = []
      parts.each do |token|
        m = token.match(/\A(?<kanji>[^()]+)\((?<kana>[^()]+)\)\z/)
        next unless m
        pairs << [m[:kanji].strip, m[:kana].strip]
      end
      pairs
    end

    # Very small romaji builder for gojūon-style consonant+vowel.
    # Consonant headers in these tables tend to be: "", K, S, T, N, H, M, Y, R, W.
    def build_romaji(consonant, vowel)
      c = normalize_cell(consonant)
      v = normalize_cell(vowel)
      return nil unless present?(v)

      c = "" if c == "∅" || c == "-" # defensive

      base = "#{c}#{v}".downcase

      # Common Hepburn-ish fixes for the gojūon:
      return "shi" if base == "si"
      return "chi" if base == "ti"
      return "tsu" if base == "tu"
      return "fu"  if base == "hu"
      return "ji"  if base == "zi"
      base
    end

    def normalize_glyph(glyph)
      g = normalize_cell(glyph)
      return nil unless present?(g)
      g = g.to_s.strip
      return nil if g.empty?
      g.each_grapheme_cluster.first
    end

    def normalize_cell(x)
      return nil if x.nil?
      s = x.to_s.tr("\u00A0", " ").strip
      s.empty? ? nil : s
    end

    def present?(s)
      !s.nil? && !s.to_s.strip.empty?
    end
  end
end
