# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "roo"
require "set"
require "stringio"
require "tempfile"
require "time"
require "yaml"
require "zip"

module Importers
  # Imports the modern-pronunciation XLSX workbooks distributed by 小學堂.
  #
  # The supplied download is one outer ZIP containing nested family ZIP files.
  # This importer reads that nested archive directly; users do not need to
  # extract or rename the workbooks first.
  #
  # Public dictionary data is deliberately narrow:
  #   * exact character
  #   * assembled phonetic reading
  #   * source citation
  #
  # Spreadsheet row numbers, notes, parser decisions, missing-cell details and
  # other working information go only to the audit CSV.
  class XiaoxuetangImporter
    DEFAULT_SOURCE = "小學堂漢字古今音資料庫".freeze
    DEFAULT_ZIP_PATH = Rails.root.join("resources", "pronunciations", "xiaoxuetang.zip")
    DEFAULT_REGISTRY_PATH = Rails.root.join("config", "pronunciation_datasets.yml")

    FAMILY_ARCHIVES = {
      "ccr04_guanhua_data_xlsx.zip" => "mandarin",
      "ccr05_jinyu_data_xlsx.zip" => "jin",
      "ccr06_wuyu_data_xlsx.zip" => "wu",
      "ccr07_huiyu_data_xlsx.zip" => "hui",
      "ccr08_ganyu_data_xlsx.zip" => "gan",
      "ccr09_xiangyu_data_xlsx.zip" => "xiang",
      "ccr10_minyu_data_xlsx.zip" => "min",
      "ccr11_yueyu_data_xlsx.zip" => "yue",
      "ccr12_pinghua_data_xlsx.zip" => "pinghua",
      "ccr13_keyu_data_xlsx.zip" => "hakka",
      "ccr14_otherdialects_data_xlsx.zip" => "other_sinitic"
    }.freeze

    HEADER_ALIASES = {
      char_number: %w[字號 order],
      character: %w[字 char character],
      initial: %w[聲母 shengmu initial],
      final: %w[韻母 yunmu final rhyme],
      tone_value: %w[調值 diaozhi tone tonevalue tone_value],
      tone_class: %w[調類 diaolei toneclass tone_class],
      note: %w[備註 comment note notes]
    }.freeze

    POSITIONAL_COLUMNS = {
      char_number: 0,
      character: 1,
      initial: 2,
      final: 3,
      tone_value: 4,
      tone_class: 5,
      note: 6
    }.freeze

    SUPERSCRIPT_DIGITS = {
      "0" => "⁰", "1" => "¹", "2" => "²", "3" => "³", "4" => "⁴",
      "5" => "⁵", "6" => "⁶", "7" => "⁷", "8" => "⁸", "9" => "⁹"
    }.freeze

    PINYIN_TONE_MARKS = {
      "ā" => "a", "á" => "a", "ǎ" => "a", "à" => "a",
      "ē" => "e", "é" => "e", "ě" => "e", "è" => "e",
      "ī" => "i", "í" => "i", "ǐ" => "i", "ì" => "i",
      "ō" => "o", "ó" => "o", "ǒ" => "o", "ò" => "o",
      "ū" => "u", "ú" => "u", "ǔ" => "u", "ù" => "u",
      "ǖ" => "ü", "ǘ" => "ü", "ǚ" => "ü", "ǜ" => "ü",
      "ń" => "n", "ň" => "n", "ǹ" => "n", "ḿ" => "m"
    }.freeze

    ZERO_COMPONENT = Object.new.freeze

    SourceRow = Struct.new(
      :row_number,
      :char_number,
      :character,
      :initial,
      :final,
      :tone_value,
      :tone_class,
      :note,
      :repairs,
      keyword_init: true
    )

    Dataset = Struct.new(
      :family,
      :dataset_id,
      :dataset_key,
      :title,
      :variety_label,
      :variety_label_en,
      :workbook_name,
      :archive_name,
      :field,
      :ruby_key,
      :metadata_warnings,
      keyword_init: true
    )

    Reading = Struct.new(
      :row,
      :character,
      :codepoint,
      :value,
      :field,
      :partial_reasons,
      :resolution_notes,
      keyword_init: true
    ) do
      def partial?
        partial_reasons.any?
      end
    end

    attr_reader :summary, :audit_dir

    def initialize(
      zip_path: DEFAULT_ZIP_PATH,
      families: nil,
      dataset_ids: nil,
      apply: false,
      replace: false,
      source: DEFAULT_SOURCE,
      audit_dir: nil,
      registry_path: DEFAULT_REGISTRY_PATH,
      write_registry: true,
      verbose: true
    )
      @zip_path = Pathname.new(zip_path.to_s).expand_path
      normalized_families = normalize_list(families)
      @families = normalized_families&.map { |value| value.downcase }&.to_set
      @dataset_ids = normalize_dataset_ids(dataset_ids)
      @apply = !!apply
      @replace = !!replace
      @source = source.to_s.strip.presence || DEFAULT_SOURCE
      @audit_dir = Pathname.new(audit_dir.presence || default_audit_dir).expand_path
      @registry_path = Pathname.new(registry_path.to_s).expand_path
      @write_registry = !!write_registry
      @verbose = !!verbose
      @summary = Hash.new(0)
      @registry_fields = {}
      @selected_dataset_count = 0
    end

    def run
      raise "Xiaoxuetang ZIP not found: #{@zip_path}" unless @zip_path.file?

      prepare_audit!
      log "mode=#{@apply ? 'APPLY' : 'DRY RUN'} zip=#{@zip_path}"
      log "families=#{@families&.to_a || 'all'} datasets=#{@dataset_ids&.to_a || 'all'}"

      # Register every selected workbook before the first database row is
      # written. Otherwise pages opened during a long import only see the
      # namespaced-field fallback (for example, "Xiaoxuetang 105") even though
      # the correct locality is already present in the workbook filename.
      preload_registry!
      raise "No workbooks matched the requested family/dataset selection" if @registry_fields.empty?
      write_registry_output!

      Zip::File.open(@zip_path.to_s) do |outer_zip|
        modern_entries = outer_zip.entries.select do |entry|
          FAMILY_ARCHIVES.key?(File.basename(entry.name))
        end

        raise "No supported modern Xiaoxuetang family archives were found" if modern_entries.empty?

        modern_entries.each do |archive_entry|
          family = FAMILY_ARCHIVES.fetch(File.basename(archive_entry.name))
          next unless selected_family?(family)

          process_family_archive(archive_entry, family)
        rescue StandardError => error
          @summary["family_archive_errors"] += 1
          audit(
            status: "archive_error",
            family: family,
            nested_archive: archive_entry.name,
            reason: "#{error.class}: #{error.message}"
          )
          log "ERROR family=#{family} #{error.class}: #{error.message}"
        end
      end

      raise "No workbooks matched the requested family/dataset selection" if @selected_dataset_count.zero?

      finish_audit!
      log_summary
      summary.transform_keys(&:to_sym)
    ensure
      @audit_csv&.close
    end

    # Rebuilds config/pronunciation_datasets.yml from the nested ZIP filenames
    # without reading pronunciation rows or touching the database. This is safe
    # to run after an import and is also useful when labels need repairing.
    def sync_registry!
      raise "Xiaoxuetang ZIP not found: #{@zip_path}" unless @zip_path.file?

      FileUtils.mkdir_p(@audit_dir)
      preload_registry!
      raise "No workbooks matched the requested family/dataset selection" if @registry_fields.empty?

      write_registry_output!(force_write: true)
      log "registry synced fields=#{@registry_fields.length} path=#{@registry_path}"
      {
        registry_fields_selected: @registry_fields.length,
        registry_path: @registry_path.to_s
      }
    end

    # Public for focused unit tests and future adapters. It resolves one
    # character group without needing a database connection.
    def resolve_group(rows, dataset:)
      candidates = {
        initial: component_candidates(rows, :initial),
        final: component_candidates(rows, :final),
        tone_value: component_candidates(rows, :tone_value)
      }

      rows.filter_map do |row|
        resolve_row(row, candidates, dataset: dataset)
      end
    end

    # ZIPs produced without the UTF-8 filename flag are awkward because
    # rubyzip may expose the same filename in more than one shape:
    #
    #   * raw Big5 bytes tagged ASCII-8BIT
    #   * a UTF-8 string containing CP437 "box drawing" mojibake
    #   * an already-correct UTF-8 filename
    #
    # Build all plausible candidates and choose the cleanest one.  Do not let
    # undecodable replacement characters leak into the public registry label.
    def decode_entry_name(name)
      value = name.to_s
      candidates = []

      utf8_view = value.dup.force_encoding(Encoding::UTF_8)
      candidates << normalize_filename_candidate(utf8_view) if utf8_view.valid_encoding?

      candidates << decode_big5_bytes(value.b)

      if utf8_view.valid_encoding?
        begin
          cp437_bytes = utf8_view.encode(Encoding.find("IBM437"))
          candidates << decode_big5_bytes(cp437_bytes)
        rescue EncodingError
          # Not a CP437-rendered filename.  The other candidates still apply.
        end
      end

      decoded = candidates.compact.max_by { |candidate| filename_candidate_score(candidate) }
      decoded.presence || "unnamed_workbook.xlsx"
    end

    def decode_big5_bytes(bytes)
      raw = bytes.to_s.b
      decoded = raw.dup.force_encoding(Encoding.find("Big5")).encode(
        Encoding::UTF_8,
        invalid: :replace,
        undef: :replace,
        replace: "�"
      )
      normalize_filename_candidate(decoded)
    rescue EncodingError
      nil
    end

    def normalize_filename_candidate(value)
      value.to_s
        .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
        .unicode_normalize(:nfc)
        .gsub(/[\u0000-\u001f\u007f]/, "")
        .strip
    end

    def filename_candidate_score(candidate)
      text = candidate.to_s
      return -1_000_000 if text.blank?

      han = text.scan(/\p{Han}/).length
      replacements = text.count("�")
      mojibake = text.scan(/[╔╗╚╝╩╦╠╣═║╬│┌┐└┘├┤┬┴┼░▒▓█▄▀]/).length
      controls = text.each_codepoint.count { |cp| cp < 32 || cp == 127 }

      (han * 100) + text.length - (replacements * 10_000) - (mojibake * 100) - (controls * 1_000)
    end

    def safe_metadata_label(value, fallback:)
      text = normalize_filename_candidate(value)
      suspicious = text.blank? || text.include?("�") ||
        text.match?(/[╔╗╚╝╩╦╠╣═║╬│┌┐└┘├┤┬┴┼░▒▓█▄▀]/)

      return [text, nil] unless suspicious

      [fallback, "unsafe_or_undecodable_workbook_label=#{value.inspect}"]
    end

    private

    def preload_registry!
      @registry_fields = {}

      Zip::File.open(@zip_path.to_s) do |outer_zip|
        outer_zip.entries.each do |archive_entry|
          archive_basename = File.basename(archive_entry.name)
          family = FAMILY_ARCHIVES[archive_basename]
          next unless family
          next unless selected_family?(family)

          bytes = archive_entry.get_input_stream.read
          Zip::File.open_buffer(StringIO.new(bytes)) do |inner_zip|
            inner_zip.entries.each do |workbook_entry|
              next if workbook_entry.directory?
              next unless workbook_entry.name.downcase.end_with?(".xlsx")

              decoded_name = decode_entry_name(workbook_entry.name)
              dataset = dataset_from_filename(decoded_name, family, archive_entry.name)
              next unless selected_dataset?(dataset)

              @registry_fields[dataset.field] = registry_entry(dataset)
            end
          end
        end
      end
    end

    def process_family_archive(archive_entry, family)
      bytes = archive_entry.get_input_stream.read
      Zip::File.open_buffer(StringIO.new(bytes)) do |inner_zip|
        inner_zip.entries.each do |workbook_entry|
          next if workbook_entry.directory?
          next unless workbook_entry.name.downcase.end_with?(".xlsx")

          decoded_name = decode_entry_name(workbook_entry.name)
          dataset = dataset_from_filename(decoded_name, family, archive_entry.name)
          next unless selected_dataset?(dataset)

          @selected_dataset_count += 1
          @summary["workbooks_selected"] += 1
          process_workbook(workbook_entry, dataset)
        rescue StandardError => error
          @summary["workbook_errors"] += 1
          audit(
            status: "workbook_error",
            family: family,
            nested_archive: archive_entry.name,
            workbook: decoded_name || workbook_entry.name,
            reason: "#{error.class}: #{error.message}"
          )
          log "ERROR workbook=#{decoded_name || workbook_entry.name} #{error.class}: #{error.message}"
        end
      end
    end

    def process_workbook(workbook_entry, dataset)
      Array(dataset.metadata_warnings).each do |warning|
        @summary["metadata_label_fallbacks"] += 1
        audit_dataset(dataset, status: "workbook_warning", reason: warning)
      end

      log "#{@apply ? 'import' : 'inspect'} #{dataset.dataset_id} #{dataset.family} #{dataset.variety_label}"

      Tempfile.create(["xiaoxuetang-#{dataset.dataset_key}-", ".xlsx"]) do |file|
        file.binmode
        IO.copy_stream(workbook_entry.get_input_stream, file)
        file.flush

        rows, header_warning = read_workbook_rows(file.path)
        if header_warning.present?
          @summary["header_fallbacks"] += 1
          audit_dataset(dataset, status: "workbook_warning", reason: header_warning)
        end

        readings = []
        contiguous_groups(rows).each do |group|
          @summary["source_rows"] += group.length
          resolved = resolve_group(group, dataset: dataset)
          readings.concat(resolved)
        rescue StandardError => error
          @summary["row_group_errors"] += 1
          first = group.first
          audit_row(
            dataset,
            first,
            status: "row_group_error",
            reason: "#{error.class}: #{error.message}"
          )
        end

        persist_readings!(readings, dataset) if @apply
        @registry_fields[dataset.field] = registry_entry(dataset) if readings.any?
        @summary["readings_ready"] += readings.length
        @summary["workbooks_processed"] += 1
      end
    end

    def read_workbook_rows(path)
      workbook = Roo::Excelx.new(path, file_warning: :ignore)
      sheet = workbook.sheet(0)
      header_row_number = find_header_row(sheet)
      raise "No usable header or data rows" unless header_row_number

      header = sheet.row(header_row_number)
      columns, warning = resolve_columns(header)
      rows = []

      ((header_row_number + 1)..sheet.last_row).each do |row_number|
        cells = sheet.row(row_number)
        next if cells.all? { |cell| clean_cell(cell).blank? }

        source_row = SourceRow.new(
          row_number: row_number,
          char_number: cell_for(cells, columns[:char_number]),
          character: cell_for(cells, columns[:character]),
          initial: cell_for(cells, columns[:initial]),
          final: cell_for(cells, columns[:final]),
          tone_value: cell_for(cells, columns[:tone_value]),
          tone_class: cell_for(cells, columns[:tone_class]),
          note: cell_for(cells, columns[:note]),
          repairs: []
        )
        rows << repair_shifted_row(source_row)
      end

      [rows, warning]
    end

    def find_header_row(sheet)
      upper = [sheet.last_row.to_i, 20].min
      (1..upper).find do |row_number|
        normalized = sheet.row(row_number).map { |value| normalize_header(value) }
        normalized.any? { |value| HEADER_ALIASES[:character].include?(value) }
      end || (sheet.last_row.to_i >= 2 ? 1 : nil)
    end

    def resolve_columns(header)
      normalized = header.map { |value| normalize_header(value) }
      columns = {}
      used_fallback = []

      HEADER_ALIASES.each do |key, aliases|
        index = normalized.index { |value| aliases.include?(value) }
        if index.nil? && POSITIONAL_COLUMNS[key] < header.length
          index = POSITIONAL_COLUMNS[key]
          used_fallback << key
        end
        columns[key] = index
      end

      raise "No character column could be identified" if columns[:character].nil?

      warning = if used_fallback.any?
        "Used positional fallback for columns: #{used_fallback.join(', ')}"
      end
      [columns, warning]
    end

    def normalize_header(value)
      clean_cell(value).downcase.gsub(/[\s_-]+/, "")
    end

    def cell_for(cells, index)
      return nil if index.nil?

      clean_cell(cells[index]).presence
    end

    def clean_cell(value)
      case value
      when nil
        ""
      when Float
        value.finite? && value == value.to_i ? value.to_i.to_s : value.to_s.strip
      else
        value.to_s.strip
      end
    end

    def meaningful_cell(value)
      text = clean_cell(value)
      return nil if text.blank? || missing_marker?(text)

      text
    end

    def missing_marker?(value)
      value.to_s.strip.match?(/\A(?:-{2,}|—+|–+|n\/?a|none|null)\z/i)
    end

    # A small number of source rows have values shifted into neighbouring
    # columns. Repair only strongly typed cases: a tone-class label is sitting
    # in the final column while a numeric tone is sitting in the tone-class
    # column. Anything less clear is left as partial data and audited.
    def repair_shifted_row(row)
      repairs = Array(row.repairs).dup

      if row.initial.blank? && consonant_like?(row.final) && row.tone_value.blank? &&
          vowel_bearing?(row.tone_class) && numeric_tone?(row.note)
        row.initial = row.final
        row.final = row.tone_class
        row.tone_value = row.note
        row.tone_class = nil
        row.note = nil
        repairs << "repaired_right_shifted_segment_and_tone"
      elsif row.tone_value.blank? && numeric_tone?(row.tone_class) && tone_class_label?(row.final)
        original_initial = row.initial
        row.tone_value = row.tone_class
        row.tone_class = row.final
        row.final = nil

        if vowel_bearing?(original_initial)
          row.final = original_initial
          row.initial = row.note.to_s.strip == "0" ? "0" : nil
          row.note = nil if row.note.to_s.strip == "0"
          repairs << "repaired_shifted_zero_initial_row"
        else
          repairs << "repaired_shifted_tone_columns"
        end
      elsif row.tone_value.blank? && numeric_tone?(row.tone_class)
        row.tone_value = row.tone_class
        row.tone_class = nil
        repairs << "repaired_numeric_tone_in_class_column"
      elsif tone_class_label?(row.tone_value) && numeric_tone?(row.tone_class)
        row.tone_value, row.tone_class = row.tone_class, row.tone_value
        repairs << "repaired_swapped_tone_columns"
      elsif numeric_tone?(row.tone_value) && row.tone_class.blank? && tone_class_label?(row.final)
        row.tone_class = row.final
        row.final = nil
        if vowel_bearing?(row.initial)
          row.final = row.initial
          row.initial = nil
        end
        repairs << "repaired_shifted_tone_class"
      end

      if repairs.any?
        @summary["source_rows_repaired"] += 1
        row.repairs = repairs
      end
      row
    end

    def numeric_tone?(value)
      text = clean_cell(value)
      text.present? && text.match?(/\A[0-9\s\/\.,;:()\-]+\z/)
    end

    def tone_class_label?(value)
      clean_cell(value).match?(/[平上去入陰阳陽輕轻促舒]/)
    end

    def vowel_bearing?(value)
      clean_cell(value).match?(/[aeiouyAEIOUYɐɑɒæɔəɛɜɞɤɨɯɪʊœøɵɶʉɚɝɿʅᴇ]/)
    end

    def consonant_like?(value)
      text = clean_cell(value)
      text.present? && !vowel_bearing?(text) && !tone_class_label?(text) && !numeric_tone?(text)
    end

    def contiguous_groups(rows)
      groups = []
      current = []
      current_key = nil

      rows.each do |row|
        key = group_key(row)
        if current.any? && key != current_key
          groups << current
          current = []
        end
        current_key = key
        current << row
      end
      groups << current if current.any?
      groups
    end

    def group_key(row)
      number = row.char_number.to_s.strip
      character = row.character.to_s.strip
      return ["row", row.row_number] if number.blank? && character.blank?

      [number.presence || "character", character]
    end

    def component_candidates(rows, attribute)
      rows.map do |row|
        component_token(row.public_send(attribute), attribute)
      end.compact.uniq
    end

    def component_token(value, attribute)
      text = meaningful_cell(value)
      return nil if text.blank?
      return ZERO_COMPONENT if %i[initial final].include?(attribute) && text == "0"

      text
    end

    def resolve_component(row, attribute, candidates)
      explicit = component_token(row.public_send(attribute), attribute)
      return [nil, :zero_explicit] if explicit.equal?(ZERO_COMPONENT)
      return [explicit, :explicit] if explicit

      if candidates.length == 1
        candidate = candidates.first
        return [nil, :zero_inherited] if candidate.equal?(ZERO_COMPONENT)
        return [candidate, :inherited]
      end

      if candidates.empty?
        return [nil, :zero_implicit] if attribute == :initial
        return [nil, :missing]
      end

      [nil, :ambiguous]
    end

    def resolve_row(row, candidates, dataset:)
      character = row.character.to_s.strip
      unless single_codepoint?(character)
        @summary["rows_skipped_bad_character"] += 1
        audit_row(
          dataset,
          row,
          status: "skipped",
          reason: character.blank? ? "missing_character" : "character_is_not_one_codepoint"
        )
        return nil
      end

      initial, initial_state = resolve_component(row, :initial, candidates[:initial])
      final, final_state = resolve_component(row, :final, candidates[:final])
      tone, tone_state = resolve_component(row, :tone_value, candidates[:tone_value])
      tone_class = meaningful_cell(row.tone_class)

      # A row may be almost entirely blank because the source uses ditto-style
      # continuation rows. Resolved/inherited material is accepted, but a bare
      # ellipsis is not a pronunciation and should not enter the dictionary.
      if initial.blank? && final.blank? && tone.blank? && tone_class.blank?
        @summary["rows_skipped_no_pronunciation"] += 1
        audit_row(dataset, row, status: "skipped", reason: "no_pronunciation_data")
        return nil
      end

      value = assemble_reading(
        initial: initial,
        initial_state: initial_state,
        final: final,
        final_state: final_state,
        tone: tone,
        tone_class: tone_class
      )

      if value.blank?
        @summary["rows_skipped_no_pronunciation"] += 1
        audit_row(dataset, row, status: "skipped", reason: "no_pronunciation_data")
        return nil
      end

      partial_reasons = partial_reasons_for(
        initial_state: initial_state,
        final_state: final_state,
        tone_state: tone_state,
        tone: tone,
        tone_class: tone_class,
        initial: initial,
        final: final
      )
      resolution_notes = Array(row.repairs) + resolution_notes_for(initial_state, final_state, tone_state)

      @summary["rows_importable"] += 1
      @summary["rows_partial"] += 1 if partial_reasons.any?
      @summary["cells_inherited"] += resolution_notes.count { |note| note.start_with?("inherited_") }

      reading = Reading.new(
        row: row,
        character: character,
        codepoint: character.ord,
        value: value,
        field: dataset.field,
        partial_reasons: partial_reasons,
        resolution_notes: resolution_notes
      )

      if reading.partial? || Array(row.repairs).any?
        status = if reading.partial?
          @apply ? "queued_partial" : "would_import_partial"
        else
          @apply ? "queued_repaired" : "would_import_repaired"
        end
        reason = reading.partial? ? reading.partial_reasons.join(";") : "source_column_repair"

        audit_row(
          dataset,
          row,
          status: status,
          reason: reason,
          value: reading.value,
          resolution: reading.resolution_notes.join(";")
        )
      end

      reading
    rescue StandardError => error
      @summary["row_errors"] += 1
      audit_row(
        dataset,
        row,
        status: "row_error",
        reason: "#{error.class}: #{error.message}"
      )
      nil
    end

    def assemble_reading(initial:, initial_state:, final:, final_state:, tone:, tone_class:)
      initial_unknown = %i[missing ambiguous].include?(initial_state)
      final_unknown = %i[missing ambiguous].include?(final_state)

      segment = +""
      if initial_unknown && final_unknown && initial.blank? && final.blank?
        segment << "…"
      else
        segment << "…" if initial_unknown
        segment << display_component(initial) if initial.present?
        segment << display_component(final) if final.present?
        segment << "…" if final_unknown
      end

      tone_text = format_tone(tone)
      if tone_text.present?
        segment = "…" if segment.blank?
        segment << tone_text
      elsif tone_class.present?
        segment = "…" if segment.blank?
        segment << "〔#{tone_class}〕"
      end

      segment.presence
    end

    def display_component(value)
      meaningful_cell(value).to_s.tr("/", "∕")
    end

    def format_tone(value)
      meaningful_cell(value).to_s
        .gsub(/\s+/, "")
        .tr("/", "∕")
        .each_char
        .map { |char| SUPERSCRIPT_DIGITS.fetch(char, char) }
        .join
    end

    def partial_reasons_for(initial_state:, final_state:, tone_state:, tone:, tone_class:, initial:, final:)
      reasons = []
      reasons << "ambiguous_initial" if initial_state == :ambiguous
      reasons << "ambiguous_final" if final_state == :ambiguous
      reasons << "ambiguous_tone" if tone_state == :ambiguous
      reasons << "missing_final" if final_state == :missing
      reasons << "missing_segment" if initial.blank? && final.blank? && final_state != :zero_explicit
      if tone.blank?
        reasons << (tone_class.present? ? "tone_class_without_tone_value" : "missing_tone")
      end
      reasons.uniq
    end

    def resolution_notes_for(initial_state, final_state, tone_state)
      {
        initial: initial_state,
        final: final_state,
        tone: tone_state
      }.filter_map do |name, state|
        case state
        when :inherited then "inherited_#{name}"
        when :zero_inherited then "inherited_zero_#{name}"
        when :zero_implicit then "implicit_zero_#{name}"
        end
      end
    end

    def single_codepoint?(value)
      value.present? && value.each_codepoint.count == 1
    rescue ArgumentError
      false
    end

    def persist_readings!(readings, dataset)
      unique_readings = readings.uniq { |reading| [reading.codepoint, reading.field, reading.value] }
      @summary["duplicates_within_workbook"] += readings.length - unique_readings.length
      return if unique_readings.empty?

      now = Time.current
      codepoints = unique_readings.map(&:codepoint).uniq

      ActiveRecord::Base.transaction do
        codepoint_rows = unique_readings.map do |reading|
          {
            codepoint: reading.codepoint,
            chr: reading.character,
            created_at: now,
            updated_at: now
          }
        end.uniq { |row| row[:codepoint] }

        # Keep batches below SQLite's conservative bind-parameter ceiling.
        codepoint_rows.each_slice(200) do |slice|
          CharacterCodepoint.insert_all(
            slice,
            unique_by: :index_character_codepoints_on_codepoint
          )
        end

        ids = {}
        codepoints.each_slice(500) do |slice|
          ids.merge!(CharacterCodepoint.where(codepoint: slice).pluck(:codepoint, :id).to_h)
        end

        if @replace
          deleted = CharacterProperty.where(source: @source, field: dataset.field).delete_all
          @summary["properties_replaced"] += deleted
        end

        records = unique_readings.filter_map do |reading|
          character_codepoint_id = ids[reading.codepoint]
          next unless character_codepoint_id

          {
            character_codepoint_id: character_codepoint_id,
            source: @source,
            field: reading.field,
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
            field: dataset.field
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

    def dataset_from_filename(decoded_name, family, archive_name)
      basename = File.basename(decoded_name, File.extname(decoded_name))
      match = basename.match(/\A\s*(\d+)\s+(.+)\z/)
      warnings = []

      if match
        dataset_id = match[1].rjust(3, "0")
        raw_title = match[2].strip
        dataset_key = dataset_id
      else
        dataset_id = "unknown"
        raw_title = basename.strip
        dataset_key = "file_#{Digest::SHA1.hexdigest(decoded_name)[0, 10]}"
      end

      title, title_warning = safe_metadata_label(
        raw_title,
        fallback: "Dataset #{dataset_id}"
      )
      warnings << title_warning if title_warning

      raw_variety = title.split("_", 2).last.to_s.strip.presence || title
      variety_label, variety_warning = safe_metadata_label(
        raw_variety,
        fallback: "Dataset #{dataset_id}"
      )
      warnings << variety_warning if variety_warning
      variety_label_en = mandarin_romanization(variety_label)

      field = "reading.#{family}.xiaoxuetang_#{dataset_key}.ipa"

      Dataset.new(
        family: family,
        dataset_id: dataset_id,
        dataset_key: dataset_key,
        title: title,
        variety_label: variety_label,
        variety_label_en: variety_label_en,
        workbook_name: decoded_name,
        archive_name: archive_name,
        field: field,
        ruby_key: "xiaoxuetang_#{dataset_key}",
        metadata_warnings: warnings
      )
    end

    def registry_entry(dataset)
      order = dataset.dataset_id.match?(/\A\d+\z/) ? dataset.dataset_id.to_i : 9_999
      {
        "family" => dataset.family,
        "label" => "IPA",
        "order" => order,
        "variety_key" => dataset.ruby_key,
        "variety_label" => dataset.variety_label,
        "variety_label_en" => dataset.variety_label_en,
        "notation" => "ipa",
        "source_dataset" => "#{dataset.dataset_id} #{dataset.title}",
        "source_archive" => File.basename(dataset.archive_name),
        "ruby" => {
          "key" => dataset.ruby_key,
          "label" => "#{dataset.variety_label} — IPA",
          "label_en" => "#{dataset.variety_label_en} — IPA",
          "sources" => [@source],
          "formatter" => "raw",
          "order" => order
        }
      }
    end

    def write_registry_output!(force_write: false)
      existing = load_registry(@registry_path)
      existing_fields = existing.fetch("fields", {})
      merged_fields = existing_fields.merge(@registry_fields) do |_field, old_entry, generated_entry|
        merge_registry_entry(old_entry, generated_entry)
      end
      output = { "fields" => merged_fields.sort.to_h }

      preview_path = @audit_dir.join("pronunciation_datasets.preview.yml")
      write_registry_file(preview_path, output)
      @summary["registry_fields_selected"] = @registry_fields.length

      return unless (@apply || force_write) && @write_registry

      FileUtils.mkdir_p(@registry_path.dirname)
      write_registry_file(@registry_path, output)
      PronunciationRegistry.reload! if defined?(PronunciationRegistry)
      @summary["registry_written"] = 1
    end

    def merge_registry_entry(existing, generated)
      old_entry = existing.is_a?(Hash) ? existing : {}
      merged = old_entry.merge(generated)

      # English labels are deliberately editable. A hand-corrected place-name
      # romanisation must survive later syncs, while the Chinese label continues
      # to follow the source filename.
      if old_entry["variety_label_en"].present?
        merged["variety_label_en"] = old_entry["variety_label_en"]
      end

      old_ruby = old_entry["ruby"].is_a?(Hash) ? old_entry["ruby"] : {}
      generated_ruby = merged["ruby"].is_a?(Hash) ? merged["ruby"] : {}
      if old_ruby["label_en"].present?
        generated_ruby["label_en"] = old_ruby["label_en"]
      end
      merged["ruby"] = generated_ruby if generated_ruby.any?
      merged
    end

    def mandarin_romanization(label)
      label.to_s.scan(/\p{Han}+|[^\p{Han}]+/).map do |segment|
        if segment.match?(/\A\p{Han}+\z/)
          syllables = PinYin.of_string(segment, :unicode)
          romanized = syllables.map { |syllable| strip_pinyin_tone(syllable.to_s) }
          next segment if romanized.empty? || romanized.any? { |syllable| syllable.match?(/\p{Han}/) }

          romanized.each_with_index.map do |syllable, index|
            index.zero? ? capitalize_pinyin(syllable) : syllable.downcase
          end.join
        else
          segment
        end
      end.join
    rescue StandardError
      label.to_s
    end

    def strip_pinyin_tone(value)
      value.each_char.map { |character| PINYIN_TONE_MARKS.fetch(character, character) }.join
    end

    def capitalize_pinyin(value)
      text = value.to_s
      return text if text.blank?

      text[0].upcase + text[1..].to_s.downcase
    end

    def load_registry(path)
      return { "fields" => {} } unless path.file?

      raw = YAML.safe_load_file(path, aliases: false) || {}
      raw["fields"] = {} unless raw["fields"].is_a?(Hash)
      raw
    rescue Psych::SyntaxError => error
      raise "Cannot read pronunciation registry #{path}: #{error.message}"
    end

    def write_registry_file(path, content)
      FileUtils.mkdir_p(path.dirname)
      header = <<~COMMENT
        # Generated/reviewed pronunciation datasets.
        #
        # Do not put spreadsheet diagnostics here. Each entry only describes a
        # user-facing pronunciation field and its source dataset.
      COMMENT
      temporary = Tempfile.new([path.basename.to_s, ".tmp"], path.dirname.to_s)
      temporary.binmode
      temporary.write(header)
      temporary.write(YAML.dump(content))
      temporary.flush
      temporary.fsync
      temporary.close
      FileUtils.mv(temporary.path, path)
    ensure
      temporary&.close!
    end

    def prepare_audit!
      FileUtils.mkdir_p(@audit_dir)
      @audit_path = @audit_dir.join("rows.csv")
      @audit_csv = CSV.open(
        @audit_path,
        "wb",
        write_headers: true,
        headers: %w[
          status family dataset_id nested_archive workbook row_number char_number
          character reason resolution value initial final tone_value tone_class note
        ]
      )
    end

    def finish_audit!
      @audit_csv&.flush
      File.write(
        @audit_dir.join("summary.json"),
        JSON.pretty_generate(
          mode: @apply ? "apply" : "dry_run",
          zip: @zip_path.to_s,
          source: @source,
          families: @families&.to_a,
          dataset_ids: @dataset_ids&.to_a,
          summary: @summary.sort.to_h
        )
      )
    end

    def audit_dataset(dataset, status:, reason:)
      audit(
        status: status,
        family: dataset.family,
        dataset_id: dataset.dataset_id,
        nested_archive: dataset.archive_name,
        workbook: dataset.workbook_name,
        reason: reason
      )
    end

    def audit_row(dataset, row, status:, reason:, resolution: nil, value: nil)
      audit(
        status: status,
        family: dataset.family,
        dataset_id: dataset.dataset_id,
        nested_archive: dataset.archive_name,
        workbook: dataset.workbook_name,
        row_number: row&.row_number,
        char_number: row&.char_number,
        character: row&.character,
        reason: reason,
        resolution: resolution,
        value: value,
        initial: row&.initial,
        final: row&.final,
        tone_value: row&.tone_value,
        tone_class: row&.tone_class,
        note: row&.note
      )
    end

    def audit(values)
      return unless @audit_csv

      @audit_csv << %w[
        status family dataset_id nested_archive workbook row_number char_number
        character reason resolution value initial final tone_value tone_class note
      ].map { |key| values[key.to_sym] }
    end

    def selected_family?(family)
      @families.nil? || @families.include?(family)
    end

    def selected_dataset?(dataset)
      return true if @dataset_ids.nil?
      return false unless dataset.dataset_id.match?(/\A\d+\z/)

      @dataset_ids.include?(dataset.dataset_id.to_i)
    end

    def normalize_list(value)
      entries = case value
      when nil then []
      when String then value.split(",")
      else Array(value)
      end.map { |entry| entry.to_s.strip }.reject(&:blank?)

      entries.presence
    end

    def normalize_dataset_ids(value)
      entries = normalize_list(value)
      return nil unless entries

      entries.filter_map do |entry|
        Integer(entry, 10)
      rescue ArgumentError
        nil
      end.to_set
    end

    def default_audit_dir
      Rails.root.join("tmp", "xiaoxuetang_imports", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
    end

    def log(message)
      puts "[xiaoxuetang] #{message}" if @verbose
    end

    def log_summary
      log "audit=#{@audit_dir}"
      @summary.sort.each { |key, value| log "#{key}=#{value}" }
    end
  end
end
