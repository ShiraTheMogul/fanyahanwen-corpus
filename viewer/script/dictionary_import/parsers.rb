# frozen_string_literal: true

require_relative "support"

module DictionaryImport
  module Parsers
    Result = Struct.new(:entries, :warnings, :metrics, keyword_init: true)

    class Base
      HAN_GROUP_RE = /\A[\p{Han}□]{1,24}\z/u
      NUMERAL_RE = /\A[〇零一二三四五六七八九十百千萬億兩]+\z/u
      PUNCT_RE = /[\s\u3000《》〈〉\(\)（）\[\]【】\{\}，,。．\.、:：;；"“”'’<>]/u
      PREFIX_FANQIE_RE = /\A(.{2}切)(.*)\z/u

      attr_reader :title, :work_id, :category, :parser_name

      def initialize(title:, work_id:, category:, parser_name:)
        @title = title
        @work_id = work_id
        @category = category
        @parser_name = parser_name
        reset_state
      end

      def parse(documents)
        reset_state
        entries = []
        warnings = []
        metrics = base_metrics

        documents.sort_by { |row| row["document_sequence"].to_i }.each do |document|
          text = DictionaryImport::Support.read_utf8(document.fetch("prepared_path"))
          maps = load_line_map(document["line_map_path"])
          lines = text.lines.map { |line| line.chomp("\n") }
          metrics[:documents] += 1
          metrics[:lines] += lines.length
          metrics[:replacement_characters] += text.count("\uFFFD")
          metrics[:unresolved_squares] += text.count("□")
          @current_document = document
          @current_lines = lines
          @current_maps = maps
          @pending_group_boundary = false
          @pending_group_boundary_source_map = nil
          before_document(document, lines, warnings, metrics)

          lines.each_with_index do |raw, index|
            next if raw.strip.empty?

            metrics[:nonblank_lines] += 1
            metrics[:max_line_length] = [metrics[:max_line_length], raw.length].max
            source_map = maps[index + 1] || {
              "source_line_start" => index + 1,
              "source_line_end" => index + 1
            }

            handled = handle_structural_line(raw, index, lines, metrics, warnings)
            next if handled
            next unless entry_mode?

            process_entry_line(raw, source_map, entries, warnings, metrics)
          end
          after_document(document, entries, warnings, metrics)
          finish_pending_group_boundary(warnings, metrics)
        end

        finish_parse(entries, warnings, metrics)
        metrics[:entries] = entries.length
        metrics[:matched_payload_ratio] = metrics[:payloads].zero? ? 0.0 : metrics[:entries].to_f / metrics[:payloads]
        metrics[:parsed_sections] = entries.filter_map do |entry|
          section = entry["section_sequence"].to_i
          [entry["document_id"], section] if section.positive?
        end.uniq.length
        metrics[:empty_detected_sections] = [metrics[:rhyme_headers].to_i - metrics[:parsed_sections], 0].max
        metrics[:observed_groups] = entries.filter_map do |entry|
          section = entry["section_sequence"].to_i
          group = entry["group_sequence"].to_i
          [entry["document_id"], section, group] if section.positive? && group.positive?
        end.uniq.length
        metrics[:group_heads] = entries.count { |entry| entry["is_group_head"] }
        metrics[:group_heads_without_fanqie] = entries.count do |entry|
          entry["is_group_head"] && entry["fanqie"].to_s.empty?
        end
        metrics[:group_heads_without_pronunciation_marker] = entries.count do |entry|
          entry["is_group_head"] && entry["pronunciation_marker_raw"].to_s.empty?
        end
        metrics[:abbreviated_cut_markers] = entries.count do |entry|
          entry["pronunciation_marker_type"] == "abbreviated_cut"
        end
        metrics[:empty_definitions] = entries.count { |entry| entry["definition"].to_s.empty? }

        Result.new(entries: entries, warnings: warnings, metrics: metrics)
      end

      def reset_state
        @entry_mode = false
        @pending_heads = nil
        @pending_group_start = false
        @pending_group_boundary = false
        @pending_group_boundary_source_map = nil
        @last_entry = nil
        @sequence = 0
        @group_sequence = 0
        @section_sequence = 0
        @tone = nil
        @tone_section = nil
        @rhyme_number = nil
        @rhyme_label = nil
        @initial = nil
        @small_rime_number = nil
      end

      def before_document(_document, _lines, _warnings, _metrics); end
      def after_document(_document, _entries, _warnings, _metrics); end

      def finish_parse(_entries, warnings, metrics)
        return unless @pending_heads&.any?

        metrics[:unmatched_head_groups] += 1
        warnings << warning(nil, nil, "final_unmatched_head_group", @pending_heads.join)
      end

      def entry_mode? = @entry_mode
      def each_entry_starts_group? = false

      def handle_structural_line(raw, _index, _lines, _metrics, _warnings)
        stripped = raw.strip
        return true if noise_line?(stripped)

        false
      end

      def noise_line?(stripped)
        stripped.empty? ||
          stripped == "欽定四庫全書" ||
          stripped.match?(/\A.+卷[〇零一二三四五六七八九十百0-9]+\z/u)
      end

      def process_entry_line(raw, source_map, entries, warnings, metrics)
        tokens = tokenize(raw)
        tokens.each_with_index do |token, token_index|
          case token.fetch(:type)
          when :outside
            queue_heads(token.fetch(:value), source_map, warnings, metrics)
          when :payload
            payload = token.fetch(:value).strip
            metrics[:payloads] += 1
            next if structural_payload?(payload)

            if @pending_heads&.any?
              group_head = @pending_group_start || @group_sequence.zero? || each_entry_starts_group?
              @group_sequence += 1 if group_head
              @small_rime_number = @group_sequence if group_head && @small_rime_number.nil?
              @sequence += 1
              entry = build_entry(payload, source_map, group_head: group_head)
              entries << entry
              @last_entry = entry
              @pending_heads = nil
              @pending_group_start = false
            elsif @pending_group_boundary
              consume_payload_after_headless_boundary(payload, source_map, entries, warnings, metrics)
            elsif continuation_payload?(payload, tokens, token_index)
              metrics[:continuation_payloads] += 1
              append_payload!(@last_entry, payload, source_map, warnings, metrics)
            else
              metrics[:unmatched_payloads] += 1
              warnings << warning(source_map, nil, "payload_without_head", payload[0, 160])
            end
          end
        end
      end

      # In these dictionary transcriptions, a physical line often means:
      #
      #   〈payload for the current head〉NEXT_HEAD
      #
      # A circle marks the start of a new pronunciation group. A tail such as
      # `柈○般` therefore does not mean that both characters share the next
      # payload. `柈` belongs to the entry whose payload has just been read;
      # `般` is the pending head for the next payload. The old parser queued
      # both together, which shifted variant heads into the following group.
      def queue_heads(segment, source_map, warnings, metrics)
        raw = segment.to_s
        if raw.include?("○")
          queue_heads_with_group_separator(raw, source_map, warnings, metrics)
          return
        end

        heads = extract_heads(raw)
        return unless heads

        group_start = heads.fetch(:group_start) || @pending_group_boundary
        if @pending_group_boundary
          metrics[:resolved_group_boundaries_without_head] += 1
          @pending_group_boundary = false
          @pending_group_boundary_source_map = nil
        end
        replace_pending_heads(heads.fetch(:heads), group_start, source_map, warnings, metrics)
      end

      def queue_heads_with_group_separator(raw, source_map, warnings, metrics)
        parts = raw.split("○", -1)
        prefix = parts.shift.to_s
        attach_heads_from_completed_entry(prefix, source_map, warnings, metrics, "before_group_separator")

        parsed_segments = []
        invalid_segments = []
        parts.each do |part|
          next if part.to_s.strip.empty?

          extracted = extract_heads(part, allow_numerals: allow_numeral_heads_in_separator_tail?)
          if extracted
            parsed_segments << extracted.fetch(:heads)
          else
            invalid_segments << part.to_s.strip
          end
        end

        invalid_segments.each do |segment|
          metrics[:unparsed_group_separator_segments] += 1
          warnings << warning(source_map, nil, "unparsed_group_separator_segment", segment[0, 160])
        end

        if parsed_segments.empty?
          @pending_group_boundary = true
          @pending_group_boundary_source_map = source_map
          metrics[:group_boundaries_without_head] += 1
          return
        end

        if parsed_segments.length > 1
          carried_segments = parsed_segments[0...-1]
          safe_variant_reassignment = carried_segments.flatten.all? do |head|
            @last_entry && @last_entry["payload_raw"].to_s.include?(head)
          end
          if safe_variant_reassignment
            metrics[:safe_multiple_separator_variant_reassignments] += 1
          else
            metrics[:multiple_group_separator_tails] += 1
            warnings << warning(
              source_map,
              nil,
              "multiple_group_separators_in_tail",
              parsed_segments.map(&:join).join("○")
            )
          end
          carried_segments.each do |heads|
            attach_head_array_to_last_entry(
              heads,
              source_map,
              warnings,
              metrics,
              "between_multiple_group_separators",
              review_required: !safe_variant_reassignment
            )
          end
        end

        @pending_group_boundary = false
        @pending_group_boundary_source_map = nil
        replace_pending_heads(parsed_segments.last, true, source_map, warnings, metrics)
      end

      def attach_heads_from_completed_entry(segment, source_map, warnings, metrics, note)
        extracted = extract_heads(segment)
        return unless extracted

        attach_head_array_to_last_entry(
          extracted.fetch(:heads),
          source_map,
          warnings,
          metrics,
          note,
          review_required: false
        )
      end

      def attach_head_array_to_last_entry(heads, source_map, warnings, metrics, note, review_required:)
        values = Array(heads).map(&:to_s).reject(&:empty?)
        return if values.empty?

        unless @last_entry
          metrics[:orphan_carryover_headwords] += values.length
          warnings << warning(source_map, nil, "orphan_carryover_headwords", values.join)
          return
        end

        added = values.reject { |head| Array(@last_entry["headwords"]).include?(head) }
        return if added.empty?

        @last_entry["headwords"] = Array(@last_entry["headwords"]) + added
        @last_entry["contains_unresolved_glyph"] ||= added.include?("□")
        @last_entry["source_line_end"] = [
          @last_entry["source_line_end"].to_i,
          source_map["source_line_end"].to_i
        ].max
        @last_entry["source_structure_notes"] = Array(@last_entry["source_structure_notes"])
        @last_entry["source_structure_notes"] << "carryover_headwords:#{note}:#{added.join}"
        if review_required
          @last_entry["parser_review_required"] = true
          @last_entry["parser_review_reasons"] = Array(@last_entry["parser_review_reasons"])
          @last_entry["parser_review_reasons"] << "multiple_group_separators_in_tail"
        end
        metrics[:carryover_headwords_reassigned] += added.length
      end

      def replace_pending_heads(heads, group_start, source_map, warnings, metrics)
        if @pending_heads&.any?
          metrics[:unmatched_head_groups] += 1
          warnings << warning(source_map, nil, "head_group_replaced", @pending_heads.join)
        end
        @pending_heads = Array(heads)
        @pending_group_start = group_start
      end

      def consume_payload_after_headless_boundary(payload, source_map, entries, warnings, metrics)
        @group_sequence += 1
        @small_rime_number = @group_sequence if @small_rime_number.nil?
        @sequence += 1
        parsed = parse_pronunciation_prefix(payload, group_head: true)
        entry = {
          "schema_version" => 3,
          "parser" => parser_name,
          "parser_version" => "source-bundle-v3",
          "dictionary_title" => title,
          "dictionary_work_id" => integer_or_string(work_id),
          "category" => category,
          "document_id" => integer_or_string(@current_document["document_id"]),
          "source_file" => @current_document["file"],
          "source_path" => @current_document["source_relative_path"],
          "source_line_start" => source_map["source_line_start"].to_i,
          "source_line_end" => source_map["source_line_end"].to_i,
          "sequence_number" => @sequence,
          "section_sequence" => @section_sequence,
          "tone" => @tone,
          "tone_section" => @tone_section,
          "rhyme_number" => @rhyme_number,
          "rhyme_label" => @rhyme_label,
          "initial" => @initial,
          "small_rime_number" => @small_rime_number,
          "group_sequence" => @group_sequence,
          "is_group_head" => true,
          "headwords" => [],
          "headword" => nil,
          "headword_status" => "missing_after_group_separator",
          "fanqie" => parsed.fetch(:fanqie),
          "pronunciation_marker_raw" => parsed.fetch(:marker_raw),
          "pronunciation_marker_type" => parsed.fetch(:marker_type),
          "definition" => parsed.fetch(:definition),
          "payload_parts" => [payload],
          "payload_raw" => payload,
          "contains_unresolved_glyph" => payload.include?("□"),
          "contains_source_gap" => true,
          "parser_review_required" => true,
          "parser_review_reasons" => ["missing_head_after_group_separator"],
          "source_structure_notes" => ["group_separator_without_following_head"]
        }
        entries << entry
        @last_entry = entry
        @pending_group_boundary = false
        @pending_group_boundary_source_map = nil
        metrics[:payloads_after_headless_group_boundary] += 1
        metrics[:source_gap_entries] += 1
        warnings << warning(source_map, nil, "payload_after_group_separator_without_head", payload[0, 160])
      end

      def finish_pending_group_boundary(warnings, metrics)
        return unless @pending_group_boundary

        metrics[:unresolved_group_boundaries_at_document_end] += 1
        warnings << warning(
          @pending_group_boundary_source_map,
          nil,
          "unresolved_group_boundary_at_document_end",
          "group separator had no following head"
        )
        @pending_group_boundary = false
        @pending_group_boundary_source_map = nil
      end

      def allow_numeral_heads_in_separator_tail? = false

      def tokenize(raw)
        tokens = []
        cursor = 0
        while (open_index = raw.index("〈", cursor))
          outside = raw[cursor...open_index]
          tokens << { type: :outside, value: outside } unless outside.to_s.empty?
          close_index = raw.index("〉", open_index + 1)
          unless close_index
            tokens << { type: :payload, value: raw[(open_index + 1)..].to_s }
            cursor = raw.length
            break
          end
          tokens << { type: :payload, value: raw[(open_index + 1)...close_index].to_s }
          cursor = close_index + 1
        end
        tail = raw[cursor..].to_s
        tokens << { type: :outside, value: tail } unless tail.empty?
        tokens
      end

      def extract_heads(segment, allow_numerals: false)
        raw = segment.to_s
        group_start = raw.include?("○")
        cleaned = raw.gsub(PUNCT_RE, "").delete("○")
        return nil if cleaned.empty?
        return nil if !allow_numerals && cleaned.match?(NUMERAL_RE)
        return nil unless cleaned.match?(HAN_GROUP_RE)
        return nil if structural_head_text?(cleaned)

        { heads: cleaned.each_char.to_a, group_start: group_start }
      end

      def structural_head_text?(_text) = false

      def structural_payload?(payload)
        payload.match?(
          /\A(?:獨用|[\p{Han}□]{1,8}(?:同用|通用)|凡[〇零一二三四五六七八九十百千0-9]+字|[〇零一二三四五六七八九十百0-9]+)\z/u
        )
      end

      def continuation_payload?(_payload, _tokens, _token_index)
        !@last_entry.nil?
      end

      def append_payload!(entry, payload, source_map, warnings = nil, metrics = nil)
        entry["payload_parts"] << payload
        entry["payload_raw"] = entry["payload_parts"].join
        parsed = parse_pronunciation_prefix(entry["payload_raw"], group_head: entry["is_group_head"])
        entry["fanqie"] = parsed.fetch(:fanqie)
        entry["pronunciation_marker_raw"] = parsed.fetch(:marker_raw)
        entry["pronunciation_marker_type"] = parsed.fetch(:marker_type)
        entry["definition"] = parsed.fetch(:definition)
        entry["source_line_end"] = source_map["source_line_end"].to_i
        after_append_payload(entry, source_map, warnings, metrics)
      end

      def after_append_payload(_entry, _source_map, _warnings, _metrics); end

      def build_entry(payload, source_map, group_head:, fanqie: :auto, definition: :auto, extras: {})
        parsed = parse_pronunciation_prefix(payload, group_head: group_head)
        fanqie = parsed.fetch(:fanqie) if fanqie == :auto
        definition = parsed.fetch(:definition) if definition == :auto

        {
          "schema_version" => 3,
          "parser" => parser_name,
          "parser_version" => "source-bundle-v3",
          "dictionary_title" => title,
          "dictionary_work_id" => integer_or_string(work_id),
          "category" => category,
          "document_id" => integer_or_string(@current_document["document_id"]),
          "source_file" => @current_document["file"],
          "source_path" => @current_document["source_relative_path"],
          "source_line_start" => source_map["source_line_start"].to_i,
          "source_line_end" => source_map["source_line_end"].to_i,
          "sequence_number" => @sequence,
          "section_sequence" => @section_sequence,
          "tone" => @tone,
          "tone_section" => @tone_section,
          "rhyme_number" => @rhyme_number,
          "rhyme_label" => @rhyme_label,
          "initial" => @initial,
          "small_rime_number" => @small_rime_number,
          "group_sequence" => @group_sequence,
          "is_group_head" => group_head,
          "headwords" => @pending_heads.dup,
          "headword" => @pending_heads.first,
          "fanqie" => fanqie,
          "pronunciation_marker_raw" => parsed.fetch(:marker_raw),
          "pronunciation_marker_type" => parsed.fetch(:marker_type),
          "definition" => definition,
          "payload_parts" => [payload],
          "payload_raw" => payload,
          "contains_unresolved_glyph" => @pending_heads.include?("□") || payload.include?("□"),
          "contains_source_gap" => false,
          "parser_review_required" => false,
          "parser_review_reasons" => [],
          "source_structure_notes" => []
        }.merge(extras)
      end

      # A pronunciation marker is read only at the start of a group-head
      # payload. Exactly two Han characters plus 切 is retained as fanqie.
      # Some sources, especially 洪武正韻, also use a one-character + 切
      # abbreviation; that is preserved separately rather than invented into a
      # full fanqie. Later phrases such as "又都貢切" stay in the definition.
      def parse_pronunciation_prefix(payload, group_head:)
        text = payload.to_s.strip
        return { fanqie: nil, marker_raw: nil, marker_type: nil, definition: text } unless group_head

        if (match = text.match(/\A([\p{Han}□]{2}切)(.*)\z/u))
          return {
            fanqie: match[1],
            marker_raw: match[1],
            marker_type: "fanqie",
            definition: match[2].to_s.strip
          }
        end
        if (match = text.match(/\A([\p{Han}□]切)(.*)\z/u))
          return {
            fanqie: nil,
            marker_raw: match[1],
            marker_type: "abbreviated_cut",
            definition: match[2].to_s.strip
          }
        end

        { fanqie: nil, marker_raw: nil, marker_type: nil, definition: text }
      end

      def split_fanqie(payload, group_head:)
        parsed = parse_pronunciation_prefix(payload, group_head: group_head)
        [parsed.fetch(:fanqie), parsed.fetch(:definition)]
      end

      def load_line_map(path)
        return {} if path.to_s.empty? || !File.file?(path)

        CSV.read(path, headers: true).each_with_object({}) do |row, out|
          out[row["prepared_line"].to_i] = row.to_h
        end
      end

      def warning(source_map, line, kind, detail)
        {
          "document_id" => @current_document && @current_document["document_id"],
          "file" => @current_document && @current_document["file"],
          "line" => line || source_map&.fetch("source_line_start", nil),
          "kind" => kind,
          "detail" => detail
        }
      end

      def integer_or_string(value)
        value.to_s.match?(/\A\d+\z/) ? value.to_i : value
      end

      def base_metrics
        Hash.new(0).merge(
          documents: 0,
          lines: 0,
          nonblank_lines: 0,
          sections: 0,
          parsed_sections: 0,
          empty_detected_sections: 0,
          observed_groups: 0,
          tone_headers: 0,
          rhyme_headers: 0,
          initial_headers: 0,
          payloads: 0,
          entries: 0,
          group_heads: 0,
          group_heads_without_fanqie: 0,
          group_heads_without_pronunciation_marker: 0,
          abbreviated_cut_markers: 0,
          declared_groups: 0,
          group_count_mismatches: 0,
          group_count_missing: 0,
          unmatched_payloads: 0,
          unmatched_head_groups: 0,
          continuation_payloads: 0,
          carryover_headwords_reassigned: 0,
          group_boundaries_without_head: 0,
          resolved_group_boundaries_without_head: 0,
          payloads_after_headless_group_boundary: 0,
          source_gap_entries: 0,
          multiple_group_separator_tails: 0,
          safe_multiple_separator_variant_reassignments: 0,
          unparsed_group_separator_segments: 0,
          orphan_carryover_headwords: 0,
          unresolved_group_boundaries_at_document_end: 0,
          replacement_characters: 0,
          unresolved_squares: 0,
          empty_definitions: 0,
          max_line_length: 0,
          matched_payload_ratio: 0.0
        )
      end

      def next_nonblank(lines, index, count: 5)
        lines[(index + 1)..].to_a.reject { |line| line.strip.empty? }.first(count)
      end

      def compact_structure_text(raw)
        raw.to_s.gsub(/[\s\u3000]+/u, "")
      end
    end

    # 廣韻 and 重修廣韻 encode the small-rime size at the end of each
    # group-head payload. This parser uses that declared count rather than
    # treating every character as a group head.
    class Guangyun < Base
      TONE_RE = /\A(上平聲|下平聲|上聲|去聲|入聲)\z/u
      RHYME_RE = /\A([〇零一二三四五六七八九十百0-9]+)([\p{Han}□]{1,4})\z/u
      COUNT_RE = /([〇零一二三四五六七八九十百]+)\z/u

      def reset_state
        super
        reset_declared_group
      end

      def before_document(_document, _lines, warnings, metrics)
        finish_declared_group(warnings, metrics)
        reset_declared_group
        @entry_mode = false
        @pending_heads = nil
        @pending_group_start = false
        @last_entry = nil
        @group_sequence = 0
        @tone = nil
        @tone_section = nil
        @counted_tones_in_document = Set.new
      end

      def after_document(_document, _entries, warnings, metrics)
        finish_declared_group(warnings, metrics)
        reset_declared_group
      end

      def finish_parse(_entries, warnings, metrics)
        finish_declared_group(warnings, metrics)
        super
      end

      def handle_structural_line(raw, index, lines, metrics, warnings)
        stripped = compact_structure_text(raw)
        if (match = stripped.match(TONE_RE))
          finish_declared_group(warnings, metrics)
          @tone = match[1]
          @tone_section = match[1]
          return true
        end
        if (match = stripped.match(RHYME_RE))
          nearby = next_nonblank(lines, index, count: 4)
          starts_entries = nearby.each_cons(2).any? do |first, second|
            extract_heads(first) && second.include?("〈")
          end
          return true unless starts_entries

          @entry_mode = true
          finish_declared_group(warnings, metrics)
          @section_sequence += 1
          @rhyme_number = DictionaryImport::Support.parse_chinese_number(match[1])
          @rhyme_label = match[2]
          @group_sequence = 0
          @small_rime_number = nil
          @pending_heads = nil
          reset_declared_group
          metrics[:rhyme_headers] += 1
          if @tone_section && !@counted_tones_in_document.include?(@tone_section)
            @counted_tones_in_document << @tone_section
            metrics[:tone_headers] += 1
          end
          return true
        end
        return true unless @entry_mode

        super
      end

      def process_entry_line(raw, source_map, entries, warnings, metrics)
        tokens = tokenize(raw)
        tokens.each_with_index do |token, token_index|
          case token.fetch(:type)
          when :outside
            queue_heads(token.fetch(:value), source_map, warnings, metrics)
          when :payload
            payload = token.fetch(:value).strip
            metrics[:payloads] += 1
            next if structural_payload?(payload)

            if @pending_heads&.any?
              consume_counted_entry(payload, source_map, entries, warnings, metrics)
            elsif @pending_group_boundary
              finish_declared_group(warnings, metrics)
              reset_declared_group
              consume_payload_after_headless_boundary(payload, source_map, entries, warnings, metrics)
            elsif continuation_payload?(payload, tokens, token_index)
              metrics[:continuation_payloads] += 1
              append_payload!(@last_entry, payload, source_map, warnings, metrics)
            else
              metrics[:unmatched_payloads] += 1
              warnings << warning(source_map, nil, "payload_without_head", payload[0, 160])
            end
          end
        end
      end

      def consume_counted_entry(payload, source_map, entries, warnings, metrics)
        info = group_head_info(payload)

        if @active_group_mode == :declared
          if info
            finish_declared_group(warnings, metrics)
            start_new_group(payload, info, source_map, entries, warnings, metrics)
          elsif @remaining_group_members.to_i.positive?
            add_declared_group_member(payload, source_map, entries)
          else
            add_declared_group_overrun(payload, source_map, entries, warnings, metrics)
          end
          return
        end

        if @active_group_mode == :unknown
          if info
            finish_declared_group(warnings, metrics)
            start_new_group(payload, info, source_map, entries, warnings, metrics)
          else
            add_unknown_group_member(payload, source_map, entries)
          end
          return
        end

        start_new_group(payload, info, source_map, entries, warnings, metrics)
      end

      def start_new_group(payload, info, source_map, entries, _warnings, metrics)
        @group_sequence += 1
        @small_rime_number = @group_sequence
        head_count = @pending_heads.length
        @observed_group_size = head_count
        @count_overrun_reported = false
        @unknown_group_reported = false
        @group_source_map = source_map
        @group_headwords = @pending_heads.dup

        if info
          @active_group_mode = :declared
          @declared_group_size = info.fetch(:count)
          @remaining_group_members = @declared_group_size - head_count
          metrics[:declared_groups] += 1
          add_entry(
            payload,
            source_map,
            entries,
            group_head: true,
            fanqie: info.fetch(:fanqie),
            definition: info.fetch(:definition),
            extras: declared_group_extras(1, head_count)
          )
        else
          @active_group_mode = :unknown
          @declared_group_size = nil
          @remaining_group_members = nil
          fanqie, definition = split_fanqie(payload, group_head: true)
          add_entry(
            payload,
            source_map,
            entries,
            group_head: true,
            fanqie: fanqie,
            definition: definition,
            extras: declared_group_extras(1, head_count)
          )
        end
      end

      def add_declared_group_member(payload, source_map, entries)
        head_count = @pending_heads.length
        start_position = @observed_group_size + 1
        @observed_group_size += head_count
        @remaining_group_members -= head_count
        add_entry(
          payload,
          source_map,
          entries,
          group_head: false,
          fanqie: nil,
          definition: payload,
          extras: declared_group_extras(start_position, @observed_group_size)
        )
      end

      def add_declared_group_overrun(payload, source_map, entries, warnings, metrics)
        head_count = @pending_heads.length
        start_position = @observed_group_size + 1
        @observed_group_size += head_count
        unless @count_overrun_reported
          metrics[:group_count_mismatches] += 1
          warnings << warning(
            source_map,
            nil,
            "declared_group_count_overrun",
            "group=#{@group_sequence}; declared=#{@declared_group_size}; observed_before=#{start_position - 1}; next_heads=#{@pending_heads.join}"
          )
          @count_overrun_reported = true
        end
        add_entry(
          payload,
          source_map,
          entries,
          group_head: false,
          fanqie: nil,
          definition: payload,
          extras: declared_group_extras(start_position, @observed_group_size)
        )
      end

      def add_unknown_group_member(payload, source_map, entries)
        head_count = @pending_heads.length
        start_position = @observed_group_size + 1
        @observed_group_size += head_count
        add_entry(
          payload,
          source_map,
          entries,
          group_head: false,
          fanqie: nil,
          definition: payload,
          extras: declared_group_extras(start_position, @observed_group_size)
        )
      end

      def add_entry(payload, source_map, entries, group_head:, fanqie: :auto, definition: :auto, extras: {})
        @sequence += 1
        entry = build_entry(
          payload,
          source_map,
          group_head: group_head,
          fanqie: fanqie,
          definition: definition,
          extras: extras
        )
        entries << entry
        @last_entry = entry
        @pending_heads = nil
        @pending_group_start = false
      end

      def group_head_info(payload)
        text = payload.to_s.strip
        fanqie_match = text.match(PREFIX_FANQIE_RE)
        return nil unless fanqie_match

        remainder = fanqie_match[2].to_s
        count_match = remainder.match(COUNT_RE)
        return nil unless count_match

        count = DictionaryImport::Support.parse_chinese_number(count_match[1])
        return nil unless count && count.positive? && count <= 200

        definition = remainder[0...count_match.begin(1)].to_s
        {
          fanqie: fanqie_match[1],
          definition: definition,
          count: count
        }
      end

      def after_append_payload(entry, source_map, _warnings, metrics)
        return unless @active_group_mode == :unknown && entry["is_group_head"]

        info = group_head_info(entry["payload_raw"])
        return unless info

        @active_group_mode = :declared
        @declared_group_size = info.fetch(:count)
        @remaining_group_members = @declared_group_size - @observed_group_size
        metrics[:declared_groups] += 1 if metrics
        entry["fanqie"] = info.fetch(:fanqie)
        entry["pronunciation_marker_raw"] = info.fetch(:fanqie)
        entry["pronunciation_marker_type"] = "fanqie"
        entry["definition"] = info.fetch(:definition)
        entry["declared_group_size"] = @declared_group_size
        entry["group_count_source"] = "payload_suffix"
        entry["source_line_end"] = source_map["source_line_end"].to_i
      end

      def declared_group_extras(position_start, position_end)
        {
          "declared_group_size" => @declared_group_size,
          "observed_group_position" => position_start,
          "observed_group_position_end" => position_end,
          "group_count_source" => @declared_group_size ? "payload_suffix" : nil
        }
      end

      def finish_declared_group(warnings, metrics)
        return unless @active_group_mode

        if @active_group_mode == :unknown
          unless @unknown_group_reported
            metrics[:group_count_missing] += 1
            warnings << warning(
              @group_source_map,
              nil,
              "group_head_without_declared_count",
              "group=#{@group_sequence}; heads=#{Array(@group_headwords).join}; observed_characters=#{@observed_group_size}"
            )
            @unknown_group_reported = true
          end
        elsif @declared_group_size && @observed_group_size != @declared_group_size && !@count_overrun_reported
          metrics[:group_count_mismatches] += 1
          warnings << warning(
            @group_source_map,
            nil,
            "declared_group_count_mismatch",
            "group=#{@group_sequence}; declared=#{@declared_group_size}; observed=#{@observed_group_size}"
          )
        end
      end

      def reset_declared_group
        @active_group_mode = nil
        @declared_group_size = nil
        @remaining_group_members = nil
        @observed_group_size = 0
        @count_overrun_reported = false
        @unknown_group_reported = false
        @group_source_map = nil
        @group_headwords = nil
      end
    end

    class Hongwu < Base
      TONE_RE = /\A(平聲|上聲|去聲|入聲)\z/u
      RHYME_RE = /\A([〇零一二三四五六七八九十百0-9]+)([\p{Han}□]{1,4})\z/u

      def allow_numeral_heads_in_separator_tail? = true

      def handle_structural_line(raw, index, lines, metrics, warnings)
        stripped = compact_structure_text(raw)
        if (match = stripped.match(TONE_RE))
          @tone = match[1]
          @tone_section = match[1]
          metrics[:tone_headers] += 1
          return true
        end
        if (match = stripped.match(RHYME_RE))
          nearby = next_nonblank(lines, index, count: 3)
          starts_entries = nearby.each_cons(2).any? { |a, b| extract_heads(a) && b.include?("〈") }
          @entry_mode ||= starts_entries
          if @entry_mode
            @section_sequence += 1
            @rhyme_number = DictionaryImport::Support.parse_chinese_number(match[1])
            @rhyme_label = match[2]
            @group_sequence = 0
            @small_rime_number = nil
            @pending_heads = nil
            metrics[:rhyme_headers] += 1
          end
          return true
        end
        return true unless @entry_mode

        super
      end

      def build_entry(payload, source_map, group_head:, **kwargs)
        @small_rime_number = @group_sequence
        super
      end
    end

    class ChongxiuGuangyun < Guangyun
      TITLE_TONE_RE = /(上平聲|下平聲|上聲|去聲|入聲)\z/u

      def handle_structural_line(raw, index, lines, metrics, warnings)
        stripped = compact_structure_text(raw)
        if (match = stripped.match(TITLE_TONE_RE))
          finish_declared_group(warnings, metrics)
          @tone = match[1]
          @tone_section = match[1]
          return true
        end
        super
      end
    end

    class Jiyun < Base
      TONE_RE = /\A(平聲|上聲|去聲|入聲)([一二三四上下]*)\z/u
      SECTION_RE = /\A([〇零一二三四五六七八九十百0-9]+)○([\p{Han}□]{1,12})\z/u

      def before_document(_document, _lines, _warnings, _metrics)
        @entry_mode = false
        @pending_heads = nil
        @pending_group_start = false
        @last_entry = nil
        @group_sequence = 0
        @rhyme_number = nil
        @rhyme_label = nil
      end

      def handle_structural_line(raw, _index, _lines, metrics, _warnings)
        stripped = compact_structure_text(raw)
        if (match = stripped.match(TONE_RE))
          @tone = match[1]
          @tone_section = match[0]
          metrics[:tone_headers] += 1
          return true
        end
        if (match = stripped.match(SECTION_RE))
          @entry_mode = true
          @section_sequence += 1
          @rhyme_number = DictionaryImport::Support.parse_chinese_number(match[1])
          heads = match[2].each_char.to_a
          @rhyme_label = heads.find { |char| char != "□" }
          @small_rime_number = nil
          @pending_heads = heads
          @pending_group_start = true
          metrics[:rhyme_headers] += 1
          return true
        end
        return true unless @entry_mode

        super
      end

      def build_entry(payload, source_map, group_head:, **kwargs)
        @small_rime_number = @group_sequence
        super
      end
    end

    class WuyinJiyun < Base
      INITIALS = %w[見 溪 羣 群 疑 端 透 定 泥 知 徹 澄 娘 精 清 從 心 邪 照 穿 牀 床 審 禪 來 日 曉 匣 影 喻 云 以].freeze
      CN = "[〇零一二三四五六七八九十百0-9]+"
      HAN = "[\\p{Han}□]+"

      def before_document(_document, _lines, _warnings, _metrics)
        @entry_mode = false
        @pending_heads = nil
        @pending_group_start = false
        @last_entry = nil
        @group_sequence = 0
        @rhyme_number = nil
        @rhyme_label = nil
        @initial = nil
        @small_rime_number = nil
      end

      def handle_structural_line(raw, index, lines, metrics, _warnings)
        stripped = compact_structure_text(raw)
        initial_alt = INITIALS.join("|")

        if (match = stripped.match(/\A(#{CN})([\p{Han}□]{1,3})(#{initial_alt})(#{HAN})\z/u))
          return true unless next_nonblank(lines, index, count: 2).any? { |line| line.include?("〈") }

          start_outer_section(match[1], match[2], match[3], match[4], metrics)
          return true
        end
        if (match = stripped.match(/\A(#{CN})([\p{Han}□]{1,3})(#{initial_alt})\z/u))
          @entry_mode = true
          @section_sequence += 1
          @rhyme_number = DictionaryImport::Support.parse_chinese_number(match[1])
          @rhyme_label = match[2]
          @initial = match[3]
          @small_rime_number = nil
          @pending_heads = nil
          @group_sequence = 0
          metrics[:rhyme_headers] += 1
          metrics[:initial_headers] += 1
          return true
        end
        if @entry_mode && INITIALS.include?(stripped)
          @initial = stripped
          @small_rime_number = nil
          metrics[:initial_headers] += 1
          return true
        end
        if @entry_mode && (match = stripped.match(/\A〈(#{CN})〉(#{HAN})\z/u))
          @small_rime_number = DictionaryImport::Support.parse_chinese_number(match[1])
          @pending_heads = match[2].each_char.to_a
          @pending_group_start = true
          return true
        end
        if @entry_mode && (match = stripped.match(/\A(#{initial_alt})(#{CN})(#{HAN})\z/u))
          @initial = match[1]
          @small_rime_number = DictionaryImport::Support.parse_chinese_number(match[2])
          @pending_heads = match[3].each_char.to_a
          @pending_group_start = true
          metrics[:initial_headers] += 1
          return true
        end
        if @entry_mode && (match = stripped.match(/\A(#{CN})(#{HAN})\z/u))
          @small_rime_number = DictionaryImport::Support.parse_chinese_number(match[1])
          @pending_heads = match[2].each_char.to_a
          @pending_group_start = true
          return true
        end
        return true unless @entry_mode

        super
      end

      def structural_payload?(_payload)
        false
      end

      def start_outer_section(number, label, initial, heads, metrics)
        @entry_mode = true
        @section_sequence += 1
        @rhyme_number = DictionaryImport::Support.parse_chinese_number(number)
        @rhyme_label = label
        @initial = initial
        @small_rime_number = nil
        @group_sequence = 0
        @pending_heads = heads.each_char.to_a
        @pending_group_start = true
        metrics[:rhyme_headers] += 1
        metrics[:initial_headers] += 1
      end
    end

    class Yupian < Base
      SECTION_RE = /\A([\p{Han}□]{1,4})部第([〇零一二三四五六七八九十百0-9]+)\z/u

      def before_document(_document, _lines, _warnings, _metrics)
        @entry_mode = false
        @pending_heads = nil
        @pending_group_start = false
        @last_entry = nil
        @group_sequence = 0
        @rhyme_number = nil
        @rhyme_label = nil
      end

      def each_entry_starts_group? = true

      def handle_structural_line(raw, index, lines, metrics, _warnings)
        stripped = compact_structure_text(raw)
        if (match = stripped.match(SECTION_RE))
          nearby = next_nonblank(lines, index, count: 4)
          actual = nearby.any? { |line| line.match?(/〈凡[〇零一二三四五六七八九十百千0-9]+字〉/) } &&
            nearby.any? { |line| extract_heads(line) }
          if actual || @entry_mode
            @entry_mode = true
            @section_sequence += 1
            @rhyme_label = "#{match[1]}部"
            @rhyme_number = DictionaryImport::Support.parse_chinese_number(match[2])
            @group_sequence = 0
            @pending_heads = nil
            metrics[:sections] += 1
          end
          return true
        end
        return true unless @entry_mode

        super
      end

      def structural_payload?(payload)
        payload.match?(/\A凡[〇零一二三四五六七八九十百千0-9]+字\z/u)
      end
    end

    class Shiming
      def initialize(title:, work_id:, category:, parser_name:)
        @title = title
        @work_id = work_id
        @category = category
        @parser_name = parser_name
      end

      def parse(documents)
        entries = []
        warnings = []
        metrics = Hash.new(0)
        section = nil
        sequence = 0

        documents.sort_by { |row| row["document_sequence"].to_i }.each do |document|
          text = DictionaryImport::Support.read_utf8(document.fetch("prepared_path"))
          maps = CSV.read(document["line_map_path"], headers: true).to_h do |row|
            [row["prepared_line"].to_i, row.to_h]
          end
          metrics[:documents] += 1
          text.lines.each_with_index do |line, index|
            stripped = line.strip
            next if stripped.empty? || stripped == "欽定四庫全書" || stripped.match?(/\A釋名卷/u)

            if stripped.match?(/\A釋[\p{Han}]{1,8}\z/u)
              section = stripped
              metrics[:sections] += 1
              next
            end
            next unless section

            segments = stripped.split(/[\s\u3000]+/).reject(&:empty?)
            segments.each do |segment|
              next if segment.length < 3

              match = segment.match(/\A(.{1,10}?)(?:者|曰)?(.{1,6})也/u)
              head = match && match[1]
              explanation_word = match && match[2]
              sequence += 1
              source = maps[index + 1] || {}
              entries << {
                "schema_version" => 3,
                "parser" => @parser_name,
                "parser_version" => "source-bundle-v3",
                "dictionary_title" => @title,
                "dictionary_work_id" => integer_or_string(@work_id),
                "category" => @category,
                "document_id" => integer_or_string(document["document_id"]),
                "source_file" => document["file"],
                "source_path" => document["source_relative_path"],
                "source_line_start" => source.fetch("source_line_start", index + 1).to_i,
                "source_line_end" => source.fetch("source_line_end", index + 1).to_i,
                "sequence_number" => sequence,
                "section" => section,
                "headword_candidate" => head,
                "paronomastic_gloss_candidate" => explanation_word,
                "raw_segment" => segment,
                "confidence" => head ? "candidate" : "low",
                "requires_review" => true
              }
              metrics[head ? :candidate_segments : :low_confidence_segments] += 1
            end
          end
        end
        metrics[:entries] = entries.length
        Result.new(entries: entries, warnings: warnings, metrics: metrics)
      end

      def integer_or_string(value)
        value.to_s.match?(/\A\d+\z/) ? value.to_i : value
      end
    end
  end
end
