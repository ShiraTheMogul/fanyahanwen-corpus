# frozen_string_literal: true

# Importers::GuangyunSikuJuanCategoriesImporter
#
# Purpose
# -------
# Guangyun "卷" plaintext (e.g. 四庫全書本 from Wikisource) contains:
#   - tone headers (上平聲 / 下平聲 / 上聲 / 去聲 / 入聲)
#   - rime headers like "一東" "二十文" etc.
#   - headword characters for each rime section.
#
# This importer scans the text sequentially, and whenever it sees a headword
# under the current (tone, rime), it writes CharacterProperty rows:
#   guangyun_tone, guangyun_rhyme, guangyun_rhyme_number, guangyun_category
#
# It is intentionally *not* a regex monster. The key idea is stateful scanning:
#   For line in file:
#     if tone header -> set tone
#     if rime header -> set rime number + name
#     else -> extract headwords from the line and attach current tone/rime

module Importers
  class GuangyunSikuJuanCategoriesImporter
    TONE_HEADERS = [
      "上平聲",
      "下平聲",
      "上聲",
      "去聲",
      "入聲"
    ].freeze

    # Matches rime section headers like:
    #   "一東" "二十文" "五十八陷" etc.
    # It should NOT match gloss lines (which contain 〈〉).
    RIME_HEADER_RE = /\A\s*([一二三四五六七八九十百]+)\s*([\p{Han}㣲㑹㡒㭘㯻㲀㶧㺖㺝㻳㼯䁆䃂䄲䇨䋸䍌䍖䎨䑎䒦䛳䜱䟵䤶䦗䫡䭹䮙䱒䳕䰤]+)\s*\z/u

    # Extract headwords inside an entry line.
    # We collect:
    #   - a single CJK character at start of the (trimmed) line
    #   - any single CJK character immediately following a closing bracket '〉'
    #
    # This is enough for Guangyun formatting where entries look like:
    #   東
    #   〈...〉菄〈...〉鶇〈...〉...
    #
    HEADWORD_AT_START_RE = /\A\s*([\p{Han}㣲㑹㡒㭘㯻㲀㶧㺖㺝㻳㼯䁆䃂䄲䇨䋸䍌䍖䎨䑎䒦䛳䜱䟵䤶䦗䫡䭹䮙䱒䳕䰤])(?=$|\s|〈)/u
    HEADWORD_AFTER_GLOSS_RE = /〉\s*([\p{Han}㣲㑹㡒㭘㯻㲀㶧㺖㺝㻳㼯䁆䃂䄲䇨䋸䍌䍖䎨䑎䒦䛳䜱䟵䤶䦗䫡䭹䮙䱒䳕䰤])/u

    # Public API
    # ---------
    # paths: array of filenames
    # source: CharacterProperty.source to write
    # wipe: if true, delete existing guangyun_(tone|rhyme|rhyme_number|category) rows for source
    # verbose: print progress
    #
    def self.import_txts(paths, source: "Guangyun (Siku)", wipe: false, verbose: false)
      new(paths, source: source, wipe: wipe, verbose: verbose).import
    end

    def initialize(paths, source:, wipe:, verbose:)
      @paths = Array(paths).map(&:to_s)
      @source = source.to_s
      @wipe = wipe
      @verbose = verbose
    end

    def import
      raise ArgumentError, "No input paths" if @paths.empty?

      if @wipe
        purge_existing!
      end

      inserted = 0
      skipped_missing_cc = 0
      warnings = 0

      # Keep only the first mapping per (cc_id, field) we see.
      # Guangyun headwords should be unique across the whole work, but this protects us.
      seen = {}

      @paths.each_with_index do |path, idx|
        say("[guangyun:juan] (#{idx + 1}/#{@paths.length}) #{path}")
        content = File.read(path, encoding: "UTF-8")

        current_tone = nil
        current_rime_name = nil
        current_rime_number = nil

        content.each_line do |line|
          raw = line
          line = line.strip
          next if line.empty?

          # Ignore metadata + markup-ish lines.
          next if line.start_with?("#")
          next if line.start_with?("<")
          next if line.include?("欽定四庫全書")
          next if line.include?("原本廣韻")

          # Tone header
          if TONE_HEADERS.include?(line)
            current_tone = line
            current_rime_name = nil
            current_rime_number = nil
            next
          end

          # Skip any line that contains gloss brackets when trying to detect a rime header.
          unless line.include?("〈") || line.include?("〉")
            if (m = line.match(RIME_HEADER_RE))
              candidate_number = chinese_numeral_to_i(m[1])
              candidate_name = m[2].to_s.strip

              # Guardrail: rime headers are short and the rime name is 1–2 Han characters.
              # This prevents false-positives like:
              #   五經文字曰其琴瑟亦用此字作
              # which starts with a Chinese numeral but is not a rime header.
              if valid_rime_header_line?(line, candidate_name)
                current_rime_number = candidate_number
                current_rime_name = candidate_name
              end
              next
            end
          end

          # If we don't have a rime context yet, there's nothing useful to attach.
          next if current_tone.nil? || current_rime_name.nil? || current_rime_number.nil?

          headwords = extract_headwords(raw)
          next if headwords.empty?

          # Resolve codepoints in one query per line batch.
          # For X in Y pattern:
          #   For chr in headwords:
          #     find CharacterCodepoint row
          codepoints = CharacterCodepoint.where(chr: headwords).pluck(:chr, :id).to_h

          headwords.each do |chr|
            cc_id = codepoints[chr]
            unless cc_id
              skipped_missing_cc += 1
              next
            end

            # Create 4 rows per character; de-dupe with `seen`.
            category = "#{current_tone}｜#{current_rime_number}.#{current_rime_name}"

            inserted += upsert_seen_row(seen, cc_id, "guangyun_tone", current_tone)
            inserted += upsert_seen_row(seen, cc_id, "guangyun_rhyme", current_rime_name)
            inserted += upsert_seen_row(seen, cc_id, "guangyun_rhyme_number", current_rime_number.to_s)
            inserted += upsert_seen_row(seen, cc_id, "guangyun_category", category)
          end
        rescue StandardError => e
          warnings += 1
          say("[guangyun:juan] WARN #{path}: #{e.class}: #{e.message}")
        end
      end

      # Bulk insert at the end for speed.
      rows = seen.values
      if rows.any?
        CharacterProperty.insert_all!(rows)
      end

      {
        inserted: rows.length,
        skipped_missing_cc: skipped_missing_cc,
        warnings: warnings
      }
    end

    private

    def purge_existing!
      scope = CharacterProperty.where(source: @source, field: [
        "guangyun_tone",
        "guangyun_rhyme",
        "guangyun_rhyme_number",
        "guangyun_category"
      ])
      count = scope.count
      scope.delete_all
      say("[guangyun:juan] purged #{count} existing mapping rows for source=#{@source.inspect}")
    end

    def say(msg)
      puts(msg) if @verbose
    end

    def self.chinese_numeral_to_i(s)
      # Handles up to 99 which is enough for Guangyun卷 headings.
      digits = {
        "一" => 1,
        "二" => 2,
        "三" => 3,
        "四" => 4,
        "五" => 5,
        "六" => 6,
        "七" => 7,
        "八" => 8,
        "九" => 9
      }
      return 10 if s == "十"

      # Patterns:
      #   十八 => 10 + 8
      #   二十 => 2*10
      #   二十三 => 2*10 + 3
      if s.include?("十")
        parts = s.split("十", 2)
        tens = parts[0].empty? ? 1 : digits.fetch(parts[0], 0)
        ones = parts[1].to_s.empty? ? 0 : digits.fetch(parts[1], 0)
        return tens * 10 + ones
      end

      # Fallback: single digit
      digits.fetch(s, 0)
    end

    def chinese_numeral_to_i(s)
      self.class.chinese_numeral_to_i(s)
    end

    def extract_headwords(raw_line)
      # Skip lines that are clearly not entry content.
      return [] if raw_line.include?("新添")

      out = []
      if (m = raw_line.match(HEADWORD_AT_START_RE))
        out << m[1]
      end
      raw_line.scan(HEADWORD_AFTER_GLOSS_RE) do |m|
        out << m[0]
      end

      # Remove placeholders / whitespace and dedupe.
      out = out.map(&:strip).reject(&:empty?)
      out.reject! { |c| c == "□" }
      out.uniq
    end

    def valid_rime_header_line?(line, rime_name)
      # Typical header: "五肴" or "二十文".
      # Keep it conservative: short line, name is 1–2 Han glyphs.
      return false if line.to_s.strip.length > 6
      return false unless rime_name.match?(/\A\p{Han}{1,2}\z/u)
      true
    end

    def upsert_seen_row(seen, cc_id, field, value)
      key = [cc_id, field]
      return 0 if seen.key?(key)

      seen[key] = {
        character_codepoint_id: cc_id,
        source: @source,
        field: field,
        value: value.to_s,
        created_at: Time.current,
        updated_at: Time.current
      }
      1
    end
  end
end
