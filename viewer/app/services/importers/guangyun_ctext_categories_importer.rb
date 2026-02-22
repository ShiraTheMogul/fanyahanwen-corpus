# frozen_string_literal: true

# app/services/importers/guangyun_ctext_categories_importer.rb
#
# Import Guangyun tone + rime categories from a simple CText-style dump.
#
# Input format (example):
#   《上平聲》
#   1. 東
#     東
#     同
#   2. 冬
#     冬
#
# This importer ONLY writes the *category mapping* fields:
#   - guangyun_tone
#   - guangyun_rhyme
#   - guangyun_rhyme_number
#   - guangyun_category   (tone｜N.rhyme)
#
# It does NOT touch guangyun_definition / fanqie / payload_raw.
#
# Why this exists:
# Your current DB has Guangyun payload fields but is missing the tone/rime mapping.
# This lets you add the missing mapping without re-importing the full text payload.

module Importers
  class GuangyunCtextCategoriesImporter
    TONE_RE = /\A《\s*(上平聲|下平聲|上聲|去聲|入聲)\s*》\s*\z/
    RHYME_RE = /\A[　\s]*([0-9]+)\s*[\.．]?\s*([^\s　]+)\s*\z/

    # Rough filter: reject punctuation and whitespace; keep Han including Ext-B.
    SKIP_CHARS_RE = /[\s　《》〈〉\[\](){}「」『』“”"'’‘，,。．\.、:：;；]/

    def self.import_file(path, default_source: "Guangyun", verbose: true, wipe: false)
      path = path.to_s
      raise "Missing file: #{path}" unless File.exist?(path)

      if wipe
        CharacterProperty.where(field: %w[guangyun_tone guangyun_rhyme guangyun_rhyme_number guangyun_category]).delete_all
      end

      tone = nil
      rhyme = nil
      rhyme_number = nil

      imported_chars = 0
      skipped_chars = 0

      File.read(path, encoding: "UTF-8").each_line.with_index(1) do |line, line_no|
        raw = line.delete("\uFEFF").strip
        next if raw.empty?

        if (m = raw.match(TONE_RE))
          tone = m[1]
          rhyme = nil
          rhyme_number = nil
          next
        end

        if tone && (m = raw.match(RHYME_RE))
          rhyme_number = m[1].to_i
          rhyme = m[2].to_s.strip
          next
        end

        next unless tone && rhyme && rhyme_number

        # Character lines: usually one glyph per line, sometimes with indentation.
        # We extract all non-punctuation chars from the line.
        glyphs = raw.gsub(SKIP_CHARS_RE, "").chars
        next if glyphs.empty?

        glyphs.each do |glyph|
          next if glyph.strip.empty?

          cc = CharacterCodepoint.find_or_create_by(codepoint: glyph.ord) { |c| c.chr = glyph }

          # Prefer to match whatever source your existing Guangyun payload rows used,
          # so the mapping sits alongside the payload for the same character.
          src = CharacterProperty
            .where(character_codepoint_id: cc.id, field: "guangyun_definition")
            .where.not(source: [nil, ""]).limit(1).pluck(:source).first
          src = src.presence || default_source

          category = "#{tone}｜#{rhyme_number}.#{rhyme}"

          upsert_prop!(cc.id, src, "guangyun_tone", tone)
          upsert_prop!(cc.id, src, "guangyun_rhyme", rhyme)
          upsert_prop!(cc.id, src, "guangyun_rhyme_number", rhyme_number.to_s)
          upsert_prop!(cc.id, src, "guangyun_category", category)

          imported_chars += 1
        rescue StandardError => e
          skipped_chars += 1
          puts "[guangyun_ctext] WARN #{path}:#{line_no} #{glyph.inspect} #{e.class}: #{e.message}" if verbose
        end
      end

      { imported_chars: imported_chars, skipped_chars: skipped_chars }
    end

    # Upsert by (ccid, source, field).
    # Pattern: delete then insert keeps idempotency even without DB uniqueness.
    def self.upsert_prop!(ccid, source, field, value)
      CharacterProperty.where(character_codepoint_id: ccid, source: source, field: field).delete_all
      CharacterProperty.create!(character_codepoint_id: ccid, source: source, field: field, value: value)
    end
  end
end
