# frozen_string_literal: true

require "csv"
require "roo"

module Importers
  # Import supplemental script datasets into CharacterCodepoint / CharacterProperty / VariantMapping.
  #
  # Core pattern (reusable elsewhere):
  # - CharacterProperty is a key/value table: (character_codepoint_id, field, source, value).
  # - To add a new kind of metadata, mint a new `field` string.
  # - Presentation is handled in FieldLens (grouping + pretty labels).
  #
  # This importer is designed to be:
  # - Idempotent: rerunning should not duplicate rows.
  # - Strict about Unicode: it always works by actual codepoints.
  class SupplementalScriptsImporter
    # ---- Public API -------------------------------------------------

    # Church Slavonic transcription characters (CSV)
    # Expected headers (from your file):
    #   char, mandarin, ipa, latin, cyrillic
    # We write:
    #   - kMandarin
    #   - context  (multi-line with IPA/Russian/Latin)
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

        if context_lines.any?
          upsert_property!(cc, field: "context", source: source, value: context_lines.join("\n"))
        end
      end
    end

    # Zetian Script / Empress Wu imposed characters (CSV)
    # Expected headers: base, wu-var, codepoint, source
    #
    # We write:
    #   - VariantMapping (base_codepoint -> variant_codepoint) with VariantMapping.source = mapping_source
    #   - context property on the *variant* character
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

    # Manyogana etymology tables (XLSX)
    # Your XLSX format:
    # - Row 1 contains consonant group headers, with blanks where the header spans multiple columns.
    # - For each vowel row, there is:
    #     row: romaji label in col 1 ("a", "i", ...)
    #     next row: kana glyphs in the same columns
    # - The cell above the kana glyph contains the manyogana kanji.
    #
    # We store the manyogana string on the kana character.
    def import_manyogana_etym_xlsx!(path, field:, source:)
      sheet = Roo::Spreadsheet.open(path).sheet(0)
      last_row = sheet.last_row
      last_col = sheet.last_column

      r = 2
      while r <= last_row
        row_key = normalize_cell(sheet.cell(r, 1))
        kana_row_key = normalize_cell(sheet.cell(r + 1, 1))

        # We only process vowel rows where the next row has nil/blank label (kana row).
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

    # Manyogana mora-table (XLSX)
    # This XLSX lists manyogana strings per kana slot in a grid.
    # It does NOT contain the kana glyphs themselves, so we use a lookup sheet
    # (your hiragana etym XLSX) to map each grid position to the kana glyph.
    #
    # kana_lookup_xlsx should be your hiragana etym XLSX.
    def import_manyogana_mora_table_xlsx!(path, kana_lookup_xlsx:, field: "jp_manyogana_mora_table", source: "manyogana_wiki")
      mora_sheet = Roo::Spreadsheet.open(path).sheet(0)
      lookup_sheet = Roo::Spreadsheet.open(kana_lookup_xlsx).sheet(0)

      mora_last_row = mora_sheet.last_row
      mora_last_col = mora_sheet.last_column
      lookup_last_row = lookup_sheet.last_row

      # Build a map: vowel_label => lookup_row_index
      # (Row index points to the row with romaji label; kana is on the next row.)
      lookup_rows = {}
      (2..lookup_last_row).each do |r|
        key = normalize_cell(lookup_sheet.cell(r, 1))
        next unless present?(key)
        lookup_rows[key] ||= r
      end

      (2..mora_last_row).each do |r|
        raw_key = normalize_cell(mora_sheet.cell(r, 1))
        next unless present?(raw_key)

        # Mora table sometimes uses i1/i2; we map both to i.
        vowel_key = raw_key.to_s[/\A[a-z]+/]
        next unless present?(vowel_key)

        lookup_r = lookup_rows[vowel_key]
        next unless lookup_r

        kana_r = lookup_r + 1

        (2..mora_last_col).each do |c|
          manyo = normalize_cell(mora_sheet.cell(r, c))
          kana = normalize_cell(lookup_sheet.cell(kana_r, c))
          next unless present?(manyo) && present?(kana)

          cc = ensure_codepoint!(kana)
          upsert_property!(cc, field: field, source: source, value: manyo)
        end
      end
    end

    # Shakuon / Shakkun CSV tables.
    # Format: first column is morae count; the other columns contain tokens like:
    #   以 (い)   嗚呼 (あ)   五十 (い)
    # Sometimes separated by commas.
    #
    # Because CharacterProperty is per-character, multi-character tokens
    # are stored on the FIRST character of the kanji token, but we preserve
    # the full token in the value string.
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

            # Store on the first character codepoint.
            first_char = kanji_token[0]
            cc = ensure_codepoint!(first_char)

            # Store a readable, stable value.
            value = "#{kanji_token} → #{kana_reading} (morae=#{morae})"
            upsert_property!(cc, field: field, source: source, value: value)
          end
        end
      end
    end

    # ---- Helpers ----------------------------------------------------

    def each_csv_row(path, &block)
      CSV.foreach(path, headers: true, encoding: "bom|utf-8") do |row|
        yield row
      end
    end

    def ensure_codepoint!(glyph)
      g = normalize_glyph(glyph)
      raise ArgumentError, "Expected a single glyph, got: #{glyph.inspect}" if g.nil?

      CharacterCodepoint.find_or_create_by!(codepoint: g.ord) do |cc|
        cc.chr = g
      end
    end

    def upsert_property!(cc, field:, source:, value:)
      v = normalize_cell(value)
      return if v.nil?

      # Unique index is (character_codepoint_id, source, field, value).
      # For idempotency, we update if any row with same cc+source+field exists.
      prop = CharacterProperty.where(character_codepoint_id: cc.id, source: source, field: field).first
      if prop
        prop.value = v
        prop.save! if prop.changed?
      else
        CharacterProperty.create!(character_codepoint_id: cc.id, field: field, source: source, value: v)
      end
    rescue ActiveRecord::RecordNotUnique
      # If concurrent / repeated writes raced, just ignore duplicates.
      true
    end

    def parse_kana_borrowing_cell(cell)
      # Split primarily on commas, then on multiple spaces.
      parts = cell.to_s.split(/[,，]/).map(&:strip)
      parts = parts.flat_map { |p| p.split(/[\s\u00A0]{2,}/) }.map(&:strip)
      parts.reject!(&:empty?)

      pairs = []
      parts.each do |token|
        # Match "KANJI (KANA)" where KANA may be hiragana/katakana or mixed.
        m = token.match(/\A(?<kanji>[^()]+)\((?<kana>[^()]+)\)\z/)
        next unless m

        kanji = m[:kanji].strip
        kana = m[:kana].strip
        pairs << [kanji, kana]
      end
      pairs
    end

    def normalize_glyph(glyph)
      g = normalize_cell(glyph)
      return nil unless present?(g)
      g = g.to_s.strip
      return nil if g.empty?

      # Some CSVs can include stray whitespace... take the first grapheme.
      g.each_grapheme_cluster.first
    end

    def normalize_cell(x)
      return nil if x.nil?
      s = x.to_s
      # Normalize common invisible spacing.
      s = s.tr("\u00A0", " ")
      s = s.strip
      s.empty? ? nil : s
    end

    def present?(s)
      !s.nil? && !s.to_s.strip.empty?
    end
  end
end
