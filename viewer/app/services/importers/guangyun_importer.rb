# frozen_string_literal: true
#
# app/services/importers/guangyun_importer.rb
#
# Guangyun (廣韻) importer for your Siku Quanshu scrape format.
#
# Input format (loosely):
#   <head_char>〈<payload>〉
#
# But in the scraped files the head character is often "offset":
#   - The head glyph appears after the previous payload closes, or on its own line.
#   - The payload is usually on the following line.
#
# So the importer uses a simple, robust queue:
#   - Scan text in reading order.
#   - Whenever we see a head glyph, enqueue it.
#   - Whenever we see a payload 〈...〉, dequeue the next head glyph and attach.
#
# Skips:
#   - Any entry whose head glyph is "□" or whose payload contains "□"
#   - Any entry with no definition content after extracting fanqie
#
# Categories:
#   - Tone headers: 《上平聲》, 《下平聲》, 《上聲》, 《去聲》, 《入聲》
#   - Rhyme section headers: "1. 東" (also accepts "1 東", "一 東", etc.)
#     The current tone + rhyme stays active until the next header.
#
# Stored fields (CharacterProperty):
#   - guangyun_tone
#   - guangyun_rhyme
#   - guangyun_rhyme_number
#   - guangyun_rhyme_note
#   - guangyun_category        (tone + rhyme, for browsing)
#   - guangyun_fanqie
#   - guangyun_definition
#   - guangyun_payload_raw
#
module Importers
  class GuangyunImporter
    TONE_RE = /\A《\s*(上平聲|下平聲|上聲|去聲|入聲)\s*》\z/

    # Common real-world patterns:
    #   1. 東
    #   1 東
    #   1.東
    #   一 東
    #   　2. 冬  (leading full-width spaces)
    RHYME_RE = /\A[　\s]*([0-9]+|[一二三四五六七八九十]+)\s*[\.．]?\s*([^\s　]+)(?:\s+.*)?\z/

    # A single "head" glyph is basically "any Han codepoint".
    # We allow Ext-B etc. \p{Han} covers most of what we want in Ruby >= 2.4.
    HAN_RE = /\p{Han}/

    # Tokenizer for one line (plus possible carry-over).
    PAYLOAD_OPEN = "〈"
    PAYLOAD_CLOSE = "〉"

    def self.import_txts(paths, source: "Guangyun (Siku)", limit: nil, verbose: true, wipe: false)
      paths = Array(paths).map(&:to_s)
      raise "No input paths" if paths.empty?

      if wipe
        CharacterProperty.where(source: source).where("field LIKE 'guangyun_%'").delete_all
      end

      state = {
        tone: nil,
        rhyme: nil,
        rhyme_number: nil,
        rhyme_note: nil
      }

      pending_heads = [] # queue
      imported = 0
      skipped = 0
      warnings = 0

      paths.each do |path|
        text = File.read(path, encoding: "UTF-8")
        juan_label = File.basename(path)

        # We need to handle payloads that can spill across lines.
        carry_payload = nil

        text.each_line.with_index(1) do |line, line_no|
          raw = line.delete("\uFEFF").rstrip
          next if raw.empty?

          # 1) Tone header
          if (m = raw.strip.match(TONE_RE))
            state[:tone] = m[1]
            state[:rhyme] = nil
            state[:rhyme_number] = nil
            state[:rhyme_note] = nil
            pending_heads.clear
            next
          end

          # 2) Rhyme header (only meaningful inside a tone)
          if state[:tone] && (m = raw.match(RHYME_RE))
            state[:rhyme_number] = normalize_number(m[1])
            state[:rhyme] = m[2].to_s.strip
            # note can appear in the next line in some versions; we keep this field,
            # but we don't try too hard here (you can refine later).
            state[:rhyme_note] = nil
            pending_heads.clear
            next
          end

          # 3) If this looks like a note line for the current rhyme, capture it.
          # In many editions you get something like "獨用" or "通用" etc.
          if state[:tone] && state[:rhyme] && state[:rhyme_note].nil?
            # A short line without payload markers and without new head entries
            # is treated as a note, if it doesn't contain obvious entry material.
            if !raw.include?(PAYLOAD_OPEN) && !raw.include?(PAYLOAD_CLOSE) && raw.length <= 12 && raw !~ HAN_RE
              # Not Han? unlikely; keep conservative and skip.
            elsif !raw.include?(PAYLOAD_OPEN) && !raw.include?(PAYLOAD_CLOSE) && raw.length <= 12 && raw !~ /切/
              # Many notes are all Han, so this branch won't help.
              # We'll use a simpler heuristic below.
            end
          end

          # 4) Process entry tokens (heads + payloads). We do this on the raw line.
          i = 0
          while i < raw.length
            if carry_payload
              # We're inside a multi-line payload (rare but happens with bad scrapes).
              close_idx = raw.index(PAYLOAD_CLOSE, i)
              if close_idx
                carry_payload << raw[i...close_idx]
                payload = carry_payload
                carry_payload = nil
                i = close_idx + 1
                consume_payload!(payload, pending_heads, state, source, juan_label, line_no, verbose: verbose,
                                 counters: { imported: -> { imported += 1 }, skipped: -> { skipped += 1 }, warnings: -> { warnings += 1 } })
              else
                carry_payload << raw[i..]
                break
              end
            else
              open_idx = raw.index(PAYLOAD_OPEN, i)
              if open_idx.nil?
                # No more payload markers; everything left is "outside payload".
                enqueue_heads!(raw[i..], pending_heads)
                break
              end

              # Outside payload: enqueue heads between i and open_idx
              enqueue_heads!(raw[i...open_idx], pending_heads)

              # Now parse the payload on this line (or start a carry).
              close_idx = raw.index(PAYLOAD_CLOSE, open_idx + 1)
              if close_idx
                payload = raw[(open_idx + 1)...close_idx]
                i = close_idx + 1
                consume_payload!(payload, pending_heads, state, source, juan_label, line_no, verbose: verbose,
                                 counters: { imported: -> { imported += 1 }, skipped: -> { skipped += 1 }, warnings: -> { warnings += 1 } })
              else
                carry_payload = raw[(open_idx + 1)..]
                break
              end
            end
          end

          break if limit && imported >= limit
        end
      end

      { imported: imported, skipped: skipped, warnings: warnings }
    end

	def self.enqueue_heads!(segment, pending_heads)
	  return if segment.nil? || segment.empty?

	  # Remove whitespace (ASCII + fullwidth), and common punctuation-like separators.
	  cleaned = segment
				  .gsub(/[[:space:]\u3000]/, "")
				  .gsub(/[《》〈〉\(\)\[\]\{\}，,。．\.、:：;；"“”'’<>]/, "")

	  return if cleaned.empty?

	  # Only accept segments that reduce to EXACTLY ONE Han glyph.
	  return unless cleaned.length == 1

	  ch = cleaned

	  return unless ch.match?(HAN_RE)
	  return if ch == "□"

	  # Exclude common Chinese numeral glyphs so headers like "四十四" can't leak in.
	  return if ch.match?(/\A[〇零一二三四五六七八九十百千萬亿億兩]\z/)

	  pending_heads << ch
	end

    def self.consume_payload!(payload, pending_heads, state, source, juan_label, line_no, verbose:, counters:)
      payload = payload.to_s.strip
      head = pending_heads.shift

      if head.nil?
        counters[:warnings].call
        puts "[Guangyun] WARN: payload with no head (#{juan_label}:#{line_no}): #{payload[0, 60].inspect}" if verbose
        counters[:skipped].call
        return
      end

      if head == "□" || payload.include?("□")
        counters[:skipped].call
        return
      end

      fanqie, definition = split_fanqie(payload)

      # User rule: if definition is missing (or effectively missing), skip.
      if definition.to_s.strip.empty?
        counters[:skipped].call
        return
      end

      cp = find_or_create_codepoint(head)

      category = build_category(state)

      props = []
      props << ["guangyun_tone", state[:tone]] if state[:tone].present?
      props << ["guangyun_rhyme", state[:rhyme]] if state[:rhyme].present?
      props << ["guangyun_rhyme_number", state[:rhyme_number]] if state[:rhyme_number].present?
      props << ["guangyun_rhyme_note", state[:rhyme_note]] if state[:rhyme_note].present?
      props << ["guangyun_category", category] if category.present?

      props << ["guangyun_fanqie", fanqie] if fanqie.present?
      props << ["guangyun_definition", definition]
      props << ["guangyun_payload_raw", payload]

      props.each do |field, value|
        next if value.blank?

        begin
          CharacterProperty.create!(
            character_codepoint_id: cp.id,
            source: source,
            field: field,
            value: value
          )
        rescue ActiveRecord::RecordNotUnique
          # duplicate - ignore
        end
      end

      counters[:imported].call
    end

    def self.split_fanqie(payload)
      s = payload.to_s.strip
      return [nil, ""] if s.empty?

      # Everything before the FIRST '切' (inclusive) is fanqie.
      idx = s.index("切")
      return [nil, s] if idx.nil?

      fanqie = s[0..idx].strip
      definition = s[(idx + 1)..].to_s.strip

      [fanqie.presence, definition]
    end

    def self.build_category(state)
      t = state[:tone].to_s.strip
      r = state[:rhyme].to_s.strip
      n = state[:rhyme_number].to_s.strip
      return "" if t.empty? || r.empty?

      n.empty? ? "#{t}｜#{r}" : "#{t}｜#{n}.#{r}"
    end

    def self.find_or_create_codepoint(glyph)
      codepoint = glyph.ord

      CharacterCodepoint.find_or_create_by(codepoint: codepoint) do |c|
        c.chr = glyph
      end
    end

    def self.normalize_number(token)
      s = token.to_s.strip
      return s if s.match?(/\A[0-9]+\z/)

      # Minimal Chinese numerals for Guangyun section numbers.
      map = {
        "一" => 1, "二" => 2, "三" => 3, "四" => 4, "五" => 5,
        "六" => 6, "七" => 7, "八" => 8, "九" => 9, "十" => 10
      }

      # Handle up to 99: "十七", "二十", "二十三"
      chars = s.each_char.to_a
      if chars.length == 1 && map[chars[0]]
        return map[chars[0]].to_s
      end

      if chars.include?("十")
        ten_idx = chars.index("十")
        left = chars[0...ten_idx]
        right = chars[(ten_idx + 1)..]

        tens = left.empty? ? 1 : map[left.join] || 0
        ones = right.empty? ? 0 : map[right.join] || 0

        val = tens * 10 + ones
        return val.to_s if val > 0
      end

      s
    end
  end
end
