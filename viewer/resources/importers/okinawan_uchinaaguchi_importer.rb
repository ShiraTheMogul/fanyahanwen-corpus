# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "pathname"
require "roo"
require "set"
require "time"

module Importers
  # Imports direct single-character Okinawan correspondences from the
  # machine-readable ninth printing of NINJAL's 沖繩語辞典.
  #
  # okinawa_02.xlsx supplies the standard-Japanese index and its Han-character
  # headwords. okinawa_01.xlsx supplies the Okinawan headwords and accent types.
  # Only index rows whose 見出しの漢字 is exactly one Han character are used.
  # Compounds and place-name appendices are deliberately outside this importer.
  #
  # Public dictionary data remains narrow:
  #   * exact Han character
  #   * source transcription
  #   * source accent class appended as an ASCII suffix (for example ?ee1)
  #   * source citation
  #
  # Spreadsheet rows, Japanese glosses, parsing decisions and unmatched-headword
  # diagnostics are written only to the audit CSV.
  class OkinawanUchinaaguchiImporter
    DEFAULT_RESOURCE_DIR = Rails.root.join("resources", "沖繩語辞典")
    DEFAULT_MAIN_PATH = DEFAULT_RESOURCE_DIR.join("okinawa_01.xlsx")
    DEFAULT_INDEX_PATH = DEFAULT_RESOURCE_DIR.join("okinawa_02.xlsx")
    DEFAULT_SOURCE = "NINJAL Okinawa-go Jiten Data Collection".freeze
    FIELD = "reading.japonic.okinawan_uchinaaguchi_shuri.ninjal".freeze

    MAIN_HEADERS = {
      page: "辞書\nページ",
      headword: "見出し語",
      accent: "アクセント型"
    }.freeze

    INDEX_HEADERS = {
      page: "辞書\nページ",
      japanese_headword: "見出し",
      han_headword: "見出しの漢字",
      explanation: "見出しの説明",
      content: "内容"
    }.freeze

    LEADING_NOTE = /\A\s*[（(][^（）()]*[）)]\s*/.freeze
    SPLIT_COMMA = /[，,、]/.freeze
    ACCENT_SPLIT = /[，,、]/.freeze
    ACCENT_CLASS_MAP = {
      "⓪" => "0",
      "①" => "1",
      "②" => "2",
      "③" => "3",
      "④" => "4",
      "⑤" => "5",
      "⑥" => "6",
      "⑦" => "7",
      "⑧" => "8",
      "⑨" => "9"
    }.freeze
    JAPANESE_OR_HAN = /[\p{Han}\p{Hiragana}\p{Katakana}]/.freeze
    LATIN_LETTER = /[A-Za-z]/.freeze

    Reading = Struct.new(
      :character,
      :codepoint,
      :value,
      :index_row,
      :index_page,
      :japanese_headword,
      :candidate,
      :accent,
      :match_status,
      keyword_init: true
    )

    attr_reader :summary, :audit_dir

    def initialize(
      main_path: DEFAULT_MAIN_PATH,
      index_path: DEFAULT_INDEX_PATH,
      apply: false,
      replace: false,
      source: DEFAULT_SOURCE,
      audit_dir: nil,
      verbose: true
    )
      @main_path = Pathname.new(main_path.to_s).expand_path
      @index_path = Pathname.new(index_path.to_s).expand_path
      @apply = !!apply
      @replace = !!replace
      @source = source.to_s.strip.presence || DEFAULT_SOURCE
      @audit_dir = Pathname.new(audit_dir.presence || default_audit_dir).expand_path
      @verbose = !!verbose
      @summary = Hash.new(0)
    end

    def run
      validate_inputs!
      prepare_audit!

      log "mode=#{@apply ? 'APPLY' : 'DRY RUN'}"
      log "main=#{@main_path}"
      log "index=#{@index_path}"

      accents_by_headword = load_accent_index
      readings = load_character_readings(accents_by_headword)
      unique_readings = readings.uniq { |reading| [reading.codepoint, reading.value] }
      @summary["duplicate_readings_removed"] += readings.length - unique_readings.length
      @summary["readings_ready"] = unique_readings.length
      @summary["characters_ready"] = unique_readings.map(&:codepoint).uniq.length

      persist_readings!(unique_readings) if @apply
      finish_audit!
      log_summary
      summary.transform_keys(&:to_sym)
    ensure
      @audit_csv&.close
    end

    private

    def validate_inputs!
      raise "Okinawan dictionary main workbook not found: #{@main_path}" unless @main_path.file?
      raise "Okinawan dictionary index workbook not found: #{@index_path}" unless @index_path.file?
    end

    def load_accent_index
      sheet = open_sheet(@main_path)
      headers = header_map(sheet, MAIN_HEADERS.values)
      accents = Hash.new { |hash, key| hash[key] = [] }

      (2..sheet.last_row).each do |row_number|
        @summary["main_rows"] += 1
        headword = clean_cell(sheet.cell(row_number, headers.fetch(MAIN_HEADERS[:headword])))
        next if headword.blank?

        accent_cell = clean_cell(sheet.cell(row_number, headers.fetch(MAIN_HEADERS[:accent])))
        parsed_accents = split_accents(accent_cell)
        parsed_accents = [nil] if parsed_accents.empty?
        accents[headword].concat(parsed_accents)
      rescue StandardError => error
        @summary["main_row_errors"] += 1
        audit(
          status: "main_row_error",
          workbook: @main_path.basename.to_s,
          row_number: row_number,
          reason: "#{error.class}: #{error.message}"
        )
      end

      accents.transform_values!(&:uniq)
      @summary["main_headwords"] = accents.length
      accents
    end

    def load_character_readings(accents_by_headword)
      sheet = open_sheet(@index_path)
      headers = header_map(sheet, INDEX_HEADERS.values)
      readings = []

      (2..sheet.last_row).each do |row_number|
        @summary["index_rows"] += 1

        han_raw = clean_cell(sheet.cell(row_number, headers.fetch(INDEX_HEADERS[:han_headword])))
        character = exact_single_han_character(han_raw)
        unless character
          @summary[han_raw.present? ? "rows_skipped_non_single_character" : "rows_without_han_headword"] += 1
          next
        end

        page = clean_cell(sheet.cell(row_number, headers.fetch(INDEX_HEADERS[:page])))
        japanese_headword = clean_cell(sheet.cell(row_number, headers.fetch(INDEX_HEADERS[:japanese_headword])))
        content = clean_cell(sheet.cell(row_number, headers.fetch(INDEX_HEADERS[:content])))
        candidates, rejected = extract_candidates(content)

        rejected.each do |item|
          @summary["candidate_fragments_audited"] += 1
          audit(
            status: item.fetch(:status),
            workbook: @index_path.basename.to_s,
            row_number: row_number,
            page: page,
            character: character,
            japanese_headword: japanese_headword,
            candidate: item[:candidate],
            reason: item.fetch(:reason)
          )
        end

        if candidates.empty?
          @summary["rows_skipped_no_direct_reading"] += 1
          audit(
            status: "skipped_no_direct_reading",
            workbook: @index_path.basename.to_s,
            row_number: row_number,
            page: page,
            character: character,
            japanese_headword: japanese_headword,
            reason: "no direct single-token Okinawan form before the first example separator"
          )
          next
        end

        @summary["single_character_rows_used"] += 1

        candidates.each do |candidate|
          expansions = accent_expansions_for(candidate, accents_by_headword)

          if expansions.first.fetch(:match_status) == "matched_main"
            @summary["candidates_matched_main"] += 1
            @summary["homophone_accent_expansions"] += [expansions.length - 1, 0].max
          else
            # The standard-language index is itself authoritative. A missing
            # exact match in the main workbook removes only accent information;
            # it does not discard the Okinawan form.
            @summary["candidates_without_main_match"] += 1
            audit(
              status: "importable_index_only",
              workbook: @index_path.basename.to_s,
              row_number: row_number,
              page: page,
              character: character,
              japanese_headword: japanese_headword,
              candidate: candidate,
              value: candidate,
              reason: "Okinawan form is present in the index but has no exact headword match in okinawa_01.xlsx; imported without accent"
            )
          end

          expansions.each do |expansion|
            readings << build_reading(
              character: character,
              candidate: candidate,
              accent: expansion[:accent],
              row_number: row_number,
              page: page,
              japanese_headword: japanese_headword,
              match_status: expansion[:match_status]
            )
          end
        end
      rescue StandardError => error
        @summary["index_row_errors"] += 1
        audit(
          status: "index_row_error",
          workbook: @index_path.basename.to_s,
          row_number: row_number,
          reason: "#{error.class}: #{error.message}"
        )
      end

      readings
    end

    def accent_expansions_for(candidate, accents_by_headword)
      accents = accents_by_headword[candidate]
      return [{ accent: nil, match_status: "index_only" }] if accents.blank?

      accents.uniq.map { |accent| { accent: accent, match_status: "matched_main" } }
    end

    def build_reading(character:, candidate:, accent:, row_number:, page:, japanese_headword:, match_status:)
      value = "#{candidate}#{accent}"
      @summary["reading_values_built"] += 1
      Reading.new(
        character: character,
        codepoint: character.ord,
        value: value,
        index_row: row_number,
        index_page: page,
        japanese_headword: japanese_headword,
        candidate: candidate,
        accent: accent,
        match_status: match_status
      )
    end

    # The index places direct equivalents before the first slash. Later slash
    # segments are examples and compounds, not standalone character readings.
    def extract_candidates(content)
      return [[], []] if content.blank?

      primary = content.to_s.split("/", 2).first.to_s
      accepted = []
      rejected = []

      primary.split(SPLIT_COMMA).each do |fragment|
        candidate = fragment.to_s.strip
        next if candidate.blank?

        loop do
          cleaned = candidate.sub(LEADING_NOTE, "").strip
          break if cleaned == candidate

          candidate = cleaned
        end

        if candidate.start_with?("→")
          rejected << {
            status: "cross_reference_only",
            candidate: candidate,
            reason: "cross-reference without a direct Okinawan form"
          }
          next
        end

        candidate = candidate.split("→", 2).first.to_s.strip if candidate.include?("→")
        next if candidate.blank?

        if candidate.match?(JAPANESE_OR_HAN)
          rejected << {
            status: "non_okinawan_fragment",
            candidate: candidate,
            reason: "fragment contains Japanese script or Han characters"
          }
          next
        end

        unless candidate.match?(LATIN_LETTER)
          rejected << {
            status: "non_reading_fragment",
            candidate: candidate,
            reason: "fragment has no Latin transcription letters"
          }
          next
        end

        if candidate.match?(/\s/)
          rejected << {
            status: "multiword_fragment",
            candidate: candidate,
            reason: "multiword lexical phrase is not treated as a single-character reading"
          }
          next
        end

        accepted << candidate
      end

      [accepted.uniq, rejected]
    end

    def split_accents(value)
      return [] if value.blank?

      value.to_s
        .split(ACCENT_SPLIT)
        .filter_map { |item| normalize_accent_class(item) }
        .uniq
    end

    # The source workbook uses circled digits for accent classes. They are
    # annotations, not part of the Okinawan spelling. Store the same class as
    # an ASCII suffix so the value remains compact and searchable: ?ee1.
    # Other source marks, such as *, are preserved exactly.
    def normalize_accent_class(value)
      normalized = value.to_s.strip
      ACCENT_CLASS_MAP.each do |source_symbol, ascii_digit|
        normalized = normalized.gsub(source_symbol, ascii_digit)
      end
      normalized.presence
    end

    def exact_single_han_character(value)
      return nil if value.blank?

      stripped = value.to_s.strip.gsub(/[〔〕\[\]【】]/, "").strip
      return nil unless stripped.each_codepoint.count == 1
      return nil unless stripped.match?(/\A\p{Han}\z/)

      stripped
    rescue ArgumentError
      nil
    end

    def open_sheet(path)
      workbook = Roo::Spreadsheet.open(path.to_s)
      workbook.sheet(0)
    rescue StandardError => error
      raise "Cannot read #{path}: #{error.class}: #{error.message}"
    end

    def header_map(sheet, required_headers)
      actual = (1..sheet.last_column).to_h do |column|
        [clean_cell(sheet.cell(1, column)), column]
      end

      missing = required_headers.reject { |header| actual.key?(header) }
      raise "Missing required columns: #{missing.join(', ')}" if missing.any?

      actual
    end

    def clean_cell(value)
      value.nil? ? nil : value.to_s.strip.presence
    end

    def persist_readings!(readings)
      return if readings.empty?

      now = Time.current
      codepoint_rows = readings.map do |reading|
        {
          codepoint: reading.codepoint,
          chr: reading.character,
          created_at: now,
          updated_at: now
        }
      end.uniq { |row| row[:codepoint] }

      ActiveRecord::Base.transaction do
        codepoint_rows.each_slice(200) do |slice|
          CharacterCodepoint.insert_all(
            slice,
            unique_by: :index_character_codepoints_on_codepoint
          )
        end

        ids = {}
        codepoint_rows.map { |row| row[:codepoint] }.each_slice(500) do |slice|
          ids.merge!(CharacterCodepoint.where(codepoint: slice).pluck(:codepoint, :id).to_h)
        end

        if @replace
          deleted = CharacterProperty.where(source: @source, field: FIELD).delete_all
          @summary["properties_replaced"] += deleted
        end

        records = readings.filter_map do |reading|
          character_codepoint_id = ids[reading.codepoint]
          next unless character_codepoint_id

          {
            character_codepoint_id: character_codepoint_id,
            source: @source,
            field: FIELD,
            value: reading.value,
            created_at: now,
            updated_at: now
          }
        end

        existing = Set.new
        records.map { |record| record[:character_codepoint_id] }.uniq.each_slice(500) do |id_slice|
          CharacterProperty.where(
            character_codepoint_id: id_slice,
            source: @source,
            field: FIELD
          ).pluck(:character_codepoint_id, :value).each do |pair|
            existing << pair
          end
        end

        new_records = records.reject do |record|
          existing.include?([record[:character_codepoint_id], record[:value]])
        end

        new_records.each_slice(150) do |slice|
          CharacterProperty.insert_all(
            slice,
            unique_by: :idx_character_properties_unique
          )
        end

        @summary["properties_inserted"] += new_records.length
        @summary["properties_existing"] += records.length - new_records.length
      end
    end

    def prepare_audit!
      FileUtils.mkdir_p(@audit_dir)
      @audit_csv = CSV.open(
        @audit_dir.join("rows.csv"),
        "wb",
        write_headers: true,
        headers: %w[
          status workbook row_number page character japanese_headword candidate
          accent value reason
        ]
      )
    end

    def audit(values)
      @audit_csv << {
        "status" => values[:status],
        "workbook" => values[:workbook],
        "row_number" => values[:row_number],
        "page" => values[:page],
        "character" => values[:character],
        "japanese_headword" => values[:japanese_headword],
        "candidate" => values[:candidate],
        "accent" => values[:accent],
        "value" => values[:value],
        "reason" => values[:reason]
      }
    end

    def finish_audit!
      @audit_csv&.flush
      File.write(
        @audit_dir.join("summary.json"),
        JSON.pretty_generate(
          mode: @apply ? "apply" : "dry_run",
          main_workbook: @main_path.to_s,
          index_workbook: @index_path.to_s,
          field: FIELD,
          source: @source,
          summary: @summary.sort.to_h
        )
      )
    end

    def default_audit_dir
      Rails.root.join("tmp", "okinawan_imports", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
    end

    def log_summary
      @summary.sort.each { |key, value| log "#{key}=#{value}" }
      log "audit=#{@audit_dir}"
    end

    def log(message)
      puts "[okinawan] #{message}" if @verbose
    end
  end
end
