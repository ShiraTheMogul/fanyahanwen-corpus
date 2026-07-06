# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "securerandom"
require "set"
require "time"
require "uri"
require "zip"

module CorpusSearchAudit
  class SkipCase < StandardError; end

  module CacheRootOverride
    def initialize(root: nil)
      audit_root = ENV["CORPUS_SEARCH_AUDIT_CACHE_ROOT"].to_s
      super(root: root || (audit_root.empty? ? nil : audit_root))
    end
  end

  unless CorpusSearch::CacheStore.ancestors.include?(CacheRootOverride)
    CorpusSearch::CacheStore.prepend(CacheRootOverride)
  end

  class Audit
    attr_reader :case_id, :case_dir, :assertions, :warnings, :metrics, :artifacts, :started_at

    def initialize(case_id:, case_dir:)
      @case_id = case_id
      @case_dir = Pathname(case_dir).expand_path
      FileUtils.mkdir_p(@case_dir)
      @assertions = []
      @warnings = []
      @metrics = {}
      @artifacts = []
      @started_at = Time.now.utc
      @monotonic_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @heartbeat_path = @case_dir.join("heartbeat.json")
      @step = nil
      heartbeat("starting")
    end

    def heartbeat(step, current: nil, total: nil, details: nil)
      @step = step.to_s
      payload = {
        "case" => case_id,
        "pid" => Process.pid,
        "step" => @step,
        "current" => current,
        "total" => total,
        "details" => details,
        "at" => Time.now.utc.iso8601
      }.compact
      atomic_write(@heartbeat_path, JSON.generate(payload))
      $stdout.sync = true
      puts("[audit][#{case_id}] #{@step}#{current ? " #{current}/#{total}" : ""}") if current.nil? || current.to_i == 1 || (current.to_i % 500).zero? || current == total
      payload
    end

    def step(name)
      heartbeat(name)
      yield
    rescue SkipCase
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException -- audit must record and continue
      record("error", name, detail: exception_detail(e))
      nil
    end

    def check(name, expected: nil, actual: nil, detail: nil)
      result = yield
      if result
        record("pass", name, expected: expected, actual: actual, detail: detail)
        true
      else
        record("fail", name, expected: expected, actual: actual, detail: detail)
        false
      end
    rescue Exception => e # rubocop:disable Lint/RescueException -- one assertion must not abort a case
      record("error", name, expected: expected, actual: actual, detail: [detail, exception_detail(e)].compact.join("\n"))
      false
    end

    def equal(name, expected, actual, detail: nil)
      check(name, expected: printable(expected), actual: printable(actual), detail: detail) { expected == actual }
    end

    def includes(name, collection, value, detail: nil)
      check(name, expected: "include #{printable(value)}", actual: printable(collection), detail: detail) do
        collection.respond_to?(:include?) && collection.include?(value)
      end
    end

    def matches(name, value, pattern, detail: nil)
      check(name, expected: pattern.inspect, actual: printable(value), detail: detail) { value.to_s.match?(pattern) }
    end

    def file(name, path, minimum_bytes: 1)
      candidate = path.nil? ? nil : Pathname(path)
      check(name, expected: "file >= #{minimum_bytes} bytes", actual: candidate&.to_s) do
        candidate&.file? && candidate.size >= minimum_bytes
      end
    rescue TypeError, ArgumentError => error
      record("error", name, expected: "file >= #{minimum_bytes} bytes", actual: path.inspect, detail: exception_detail(error))
      false
    end

    def warn(message, data = nil)
      entry = { "message" => message.to_s, "data" => data, "at" => Time.now.utc.iso8601 }.compact
      @warnings << entry
      puts "[audit][#{case_id}][warning] #{message}"
      entry
    end

    def metric(name, value)
      @metrics[name.to_s] = value
    end

    def artifact(path, kind: nil, description: nil)
      candidate = Pathname(path).expand_path
      @artifacts << {
        "path" => candidate.to_s,
        "kind" => kind,
        "description" => description,
        "bytes" => candidate.file? ? candidate.size : nil
      }.compact
      candidate
    end

    def skip!(reason)
      warn(reason)
      raise SkipCase, reason
    end

    def finish(status_override: nil, error: nil)
      ended_at = Time.now.utc
      status = status_override || inferred_status
      payload = {
        "case_id" => case_id,
        "status" => status,
        "started_at" => started_at.iso8601,
        "ended_at" => ended_at.iso8601,
        "duration_seconds" => elapsed.round(4),
        "last_step" => @step,
        "assertion_counts" => @assertions.group_by { |row| row.fetch("status") }.transform_values(&:length),
        "assertions" => @assertions,
        "warnings" => @warnings,
        "metrics" => @metrics,
        "artifacts" => @artifacts,
        "error" => error
      }.compact
      atomic_write(@case_dir.join("case_result.json"), JSON.pretty_generate(payload))
      heartbeat("finished", details: { status: status })
      payload
    end

    def elapsed
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - @monotonic_started
    end

    private

    def inferred_status
      states = @assertions.map { |row| row.fetch("status") }
      states.any? { |state| %w[fail error].include?(state) } ? "failed" : "passed"
    end

    def record(status, name, expected: nil, actual: nil, detail: nil)
      row = {
        "status" => status,
        "name" => name.to_s,
        "expected" => expected,
        "actual" => actual,
        "detail" => detail,
        "step" => @step,
        "at" => Time.now.utc.iso8601
      }.compact
      @assertions << row
      marker = status == "pass" ? "PASS" : status.upcase
      puts "[audit][#{case_id}][#{marker}] #{name}"
      row
    end

    def printable(value)
      case value
      when String
        value.length > 1_000 ? "#{value[0, 1_000]}… (#{value.length} chars)" : value
      else
        JSON.generate(value)
      end
    rescue JSON::GeneratorError, TypeError
      value.inspect
    end

    def exception_detail(error)
      (["#{error.class}: #{error.message}"] + Array(error.backtrace).first(20)).join("\n")
    end

    def atomic_write(path, contents)
      temporary = path.dirname.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      FileUtils.mkdir_p(path.dirname)
      temporary.binwrite(contents)
      FileUtils.mv(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end
  end

  module SyntheticCorpus
    VERSION = 5
    module_function

    def build!(root)
      root = Pathname(root).expand_path
      FileUtils.rm_rf(root)
      FileUtils.mkdir_p(root)

      write(root, "中國漢文/clean/周朝/詩經/關雎.txt", <<~TEXT)
        # TITLE: 關雎
        # AUTHOR: 詩經編者
        # YEAR_START: -1046
        # YEAR_END: -771
        # TIMES: 西周
        # NATION: 中國漢文
        # REGION: 周

        關關雎鳩，在河之洲。窈窕淑女，君子好逑。
      TEXT
      write(root, "中國漢文/clean/宋朝/三字經/三字經.txt", <<~TEXT)
        # TITLE: 三字經
        # AUTHOR: 王應麟
        # YEAR_START: 1223
        # YEAR_END: 1296
        # TIMES: 南宋
        # NATION: 中國漢文
        # REGION: 慶元府

        人之初，性本善。性相近，習相遠。苟不教，性乃遷。教之道，貴以專。
      TEXT
      write(root, "中國漢文/clean/周朝/舜孝.txt", <<~TEXT)
        # TITLE: 舜孝
        # AUTHOR: 測試者
        # YEAR_START: -300
        # TIMES: 戰國
        # NATION: 中國漢文
        # REGION: 魯

        舜，克孝，聞於天下。民與民共事君。甲乙丙丁戊己庚辛壬癸。
      TEXT
      write(root, "中國漢文/clean/周朝/仁義.txt", <<~TEXT)
        # TITLE: 仁義正文
        # AUTHOR: 孟子
        # YEAR_START: -300
        # TIMES: 戰國
        # NATION: 中國漢文
        # REGION: 鄒

        君子仁而有義。仁義並行。人之初亦可見。
      TEXT
      write(
        root,
        "中國漢文/clean/周朝/dense_occurrences.txt",
        header("密集命中", nation: "中國漢文", period: "周朝", region: "壓力測試", year: -250) +
          Array.new(1_105, "密集詞").join("，") + "。\n"
      )
      write(root, "中國漢文/clean/周朝/metadata_only.txt", <<~TEXT)
        # TITLE: 關關雎鳩在河之洲 只在標題 仁義
        # AUTHOR: 舜孝
        # YEAR_START: -200
        # TIMES: 戰國
        # NATION: 中國漢文
        # REGION: 測試

        此正文全無那些檢索詞。
      TEXT
      write(root, "日本漢文/clean/江戶時代/試驗.txt", <<~TEXT)
        # TITLE: 試験
        # AUTHOR: 日本作者
        # YEAR_START: 1750
        # TIMES: 江戶時代
        # NATION: 日本漢文
        # REGION: 江戶

        試験之法，溫故知新。
      TEXT
      write(root, "中國漢文/clean/周朝/roles/received.txt", header("正本文", nation: "中國漢文", period: "周朝", region: "角色", year: -200) + "正本文，角色檢查。\n")
      write(root, "中國漢文/clean/周朝/roles/variants/variant.txt", header("異本文", nation: "中國漢文", period: "周朝", region: "角色", year: -190) + "異本文，角色檢查。\n")
      write(root, "中國漢文/raw/周朝/roles/raw.txt", header("原始文", nation: "中國漢文", period: "周朝", region: "角色", year: -180) + "原始文，角色檢查。\n")
      write(root, "中國漢文/clean/周朝/roles/kanbun/reading.txt", header("訓讀文", nation: "中國漢文", period: "周朝", region: "角色", year: -170) + "訓讀文，角色檢查。\n")
      write(root, "中國漢文/clean/周朝/roles/translations/en.txt", header("譯本文", nation: "中國漢文", period: "周朝", region: "角色", year: -160) + "譯本文，角色檢查。\n")
      write(root, "中國漢文/clean/周朝/roles/annotations/note.txt", header("注釋文", nation: "中國漢文", period: "周朝", region: "角色", year: -150) + "注釋文，角色檢查。\n")
      write(root, "misc/support.txt", "支援文，不應進入搜尋。\n")

      144.times do |index|
        nation = ["中國漢文", "日本漢文", "越南漢文"][index % 3]
        period = ["甲期", "乙期", "丙期", "丁期"][index % 4]
        region = ["東部", "西部", "南部", "北部"][index % 4]
        year = 800 + (index * 8)
        terms = []
        terms << "人之初性本善" if index.even?
        terms << "仁義" if (index % 3).zero?
        terms << "舜克孝聞於天下" if (index % 4).zero?
        terms << "關關雎鳩在河之洲" if (index % 5).zero?
        terms << "試験溫故" if (index % 6).zero?
        terms << "甲乙丙丁戊己庚辛壬癸" if (index % 7).zero?
        terms << "無命中正文"
        body = if (index % 18).zero?
          "重複正文。人之初，性本善。仁義。"
        else
          "測試文書#{index}。#{terms.join("。")}。"
        end
        path = format("%s/clean/%s/%s/generated_%03d.txt", nation, period, region, index)
        write(root, path, header("生成測試#{index}", author: "作者#{index % 12}", nation: nation, period: period, region: region, year: year) + body + "\n")
      end

      invalid = root.join("中國漢文/clean/周朝/invalid_utf8.txt")
      FileUtils.mkdir_p(invalid.dirname)
      invalid.binwrite("# TITLE: 壞編碼\n# YEAR_START: 100\n\n人之初\xFF\xFE性本善\n".b)

      symlink_target = root.join("outside.txt")
      symlink_target.write("人之初，但符號連結不應入索引。\n")
      symlink_path = root.join("中國漢文/clean/周朝/symlink.txt")
      File.symlink(symlink_target, symlink_path)

      root.join(".audit_corpus_version").write(VERSION.to_s)
      root
    end

    def header(title, author: "測試作者", nation:, period:, region:, year:)
      <<~TEXT
        # TITLE: #{title}
        # AUTHOR: #{author}
        # YEAR_START: #{year}
        # YEAR_END: #{year}
        # TIMES: #{period}
        # NATION: #{nation}
        # REGION: #{region}

      TEXT
    end

    def write(root, relative, content)
      path = root.join(relative)
      FileUtils.mkdir_p(path.dirname)
      path.write(content, encoding: "UTF-8")
      path
    end
  end

  module Helpers
    module_function

    def cache(case_dir, name = "cache")
      CorpusSearch::CacheStore.new(root: Pathname(case_dir).join(name))
    end

    def with_corpus(root)
      previous = Rails.configuration.x.corpus_root
      Rails.configuration.x.corpus_root = Pathname(root).expand_path.to_s
      yield
    ensure
      Rails.configuration.x.corpus_root = previous
    end

    def build_manifest(root:, cache_store:, audit: nil, force: true)
      with_corpus(root) do
        CorpusSearch::Manifest.load(root: root, cache_store: cache_store, refresh: true, force: force).tap do |manifest|
          audit&.metric("manifest_documents", manifest.documents.length)
        end
      end
    end

    def build_query(mode: "exact", q: nil, terms: nil, span: 200, order: "any", punctuation: "ignore",
                    characters: "exact", metadata: {}, roles: nil, folders: nil, exclude_folders: nil,
                    context: 20, page: 1, per_page: 20)
      definition = CorpusSearch::SearchDefinition.new(
        mode: mode,
        query_text: q,
        terms: terms,
        maximum_span: span,
        order: order,
        punctuation: punctuation,
        character_equivalence: characters,
        metadata_filters: metadata,
        document_roles: roles,
        include_folders: folders,
        exclude_folders: exclude_folders
      )
      presentation = CorpusSearch::PresentationOptions.new(context: context, page: page, per_page: per_page)
      CorpusSearch::Query.new(search_definition: definition, presentation_options: presentation, requested: true)
    end

    def run_page(root:, cache_store:, manifest:, **query_options)
      query = build_query(**query_options)
      page = with_corpus(root) { CorpusSearch::Runner.new(query: query, manifest: manifest, cache_store: cache_store).page }
      [query, page]
    end

    def run_prepared(root:, cache_store:, query:, comparison: nil, source: nil, audit: nil)
      with_corpus(root) do
        prepared = CorpusSearch::PreparedSearch.create!(
          query: query,
          comparison: comparison,
          source_prepared: source,
          cache_store: cache_store
        )
        audit&.heartbeat("prepared export #{prepared.id}")
        zip = CorpusSearch::ExportWriter.new(prepared_search: prepared, cache_store: cache_store).write!
        prepared.load!
        [prepared, zip]
      end
    end

    def timed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = yield
      [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end

    def shared_registry(run_root)
      path = Pathname(run_root).join("shared", "exports.json")
      FileUtils.mkdir_p(path.dirname)
      payload = path.file? ? JSON.parse(path.read) : {}
      yield payload
      temporary = path.dirname.join(".exports.#{Process.pid}.tmp")
      temporary.write(JSON.pretty_generate(payload))
      FileUtils.mv(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def record_export(run_root, key, prepared, root:, cache_root:)
      shared_registry(run_root) do |payload|
        payload[key.to_s] = {
          "id" => prepared.id,
          "key" => prepared.key,
          "root" => Pathname(root).expand_path.to_s,
          "cache_root" => Pathname(cache_root).expand_path.to_s,
          "output_dir" => prepared.output_dir.to_s,
          "zip_path" => prepared.zip_path&.to_s,
          "recorded_at" => Time.now.utc.iso8601
        }
      end
    end

    def read_export(run_root, key)
      path = Pathname(run_root).join("shared", "exports.json")
      return nil unless path.file?

      JSON.parse(path.read)[key.to_s]
    rescue JSON::ParserError
      nil
    end

    def choose_branch(manifest, hit_path, minimum: 8, maximum: 5_000)
      parts = File.dirname(hit_path.to_s).split("/")
      candidates = (1..parts.length).map { |length| parts.first(length).join("/") }
      counts = candidates.to_h do |folder|
        [folder, manifest.filtered("include_folders" => [folder], "document_roles" => ["canonical"]).length]
      end
      eligible = counts.select { |_folder, count| count >= minimum && count <= maximum }
      return eligible.max_by { |_folder, count| count }&.first if eligible.any?

      under_maximum = counts.select { |_folder, count| count.positive? && count <= maximum }
      under_maximum.max_by { |_folder, count| count }&.first || File.dirname(hit_path.to_s)
    end
  end

  class ArtifactValidator
    REQUIRED_ROOT_FILES = %w[
      results.csv flashcards.csv document_counts.csv analysis_occurrences.csv analysis_dataset.json
      query.json query_urls.txt corpus_snapshot.json RERUN_ANALYSIS.txt metadata.json README.txt
      METHODS.md METHODS.txt CITATION.txt research_manifest.json checksums.sha256
    ].freeze
    REQUIRED_ANALYSIS_FILES = %w[
      analysis.rb run_metadata.json analysis_report.json summary.csv period_summary.csv nation_summary.csv
      region_summary.csv author_summary.csv folder_summary.csv document_role_summary.csv chart_manifest.csv
      matches_per_document.csv top_documents.csv concentration_summary.csv neighbour_characters.csv
      neighbour_window_summary.csv character_form_summary.csv sample_documents.csv sample_occurrences.csv
      sampling_manifest.csv comparison_neighbour_keyness.csv dispersion_summary.csv dimension_dispersion.csv duplicate_body_groups.csv
      duplicate_body_members.csv duplicate_body_summary.csv exact_body_sensitivity.csv time_bins.csv
      time_trend_model.csv timing.csv runtime_info.txt warnings.txt stdout.txt stderr.txt
    ].freeze

    def initialize(audit)
      @audit = audit
    end

    def validate!(prepared, require_analysis: true, expected_mode: nil, expected_special_files: [])
      prepared.load!
      output = prepared.output_dir
      @audit.artifact(output, kind: "directory", description: "Prepared export directory")
      @audit.equal("prepared record completed", "complete", prepared.status)
      @audit.check("prepared record is frozen", expected: true, actual: prepared.frozen?) { prepared.frozen? }
      @audit.file("prepared ZIP exists", prepared.zip_path, minimum_bytes: 100)

      REQUIRED_ROOT_FILES.each { |name| @audit.file("root artefact #{name}", output.join(name), minimum_bytes: name.end_with?("stderr.txt", "warnings.txt") ? 0 : 1) }
      analysis = output.join("analysis", "standard")
      REQUIRED_ANALYSIS_FILES.each do |name|
        minimum = %w[warnings.txt stdout.txt stderr.txt].include?(name) ? 0 : 1
        @audit.file("analysis artefact #{name}", analysis.join(name), minimum_bytes: minimum)
      end
      Array(expected_special_files).each { |name| @audit.file("mode-specific analysis artefact #{name}", analysis.join(name), minimum_bytes: 1) }

      validate_json(output.join("analysis_dataset.json"))
      validate_json(output.join("query.json"))
      validate_json(output.join("corpus_snapshot.json"))
      validate_json(output.join("metadata.json"))
      validate_json(output.join("research_manifest.json"))
      report = validate_json(analysis.join("analysis_report.json"))
      run_metadata = validate_json(analysis.join("run_metadata.json"))

      if require_analysis
        @audit.equal("analysis run status", "complete", run_metadata && run_metadata["status"])
        @audit.check("analysis report has charts", expected: "> 0", actual: Array(report && report["charts"]).length) do
          Array(report && report["charts"]).any?
        end
      end

      query_payload = JSON.parse(output.join("query.json").read) rescue {}
      @audit.equal("exported query mode", expected_mode, query_payload.dig("query", "definition", "mode")) if expected_mode

      validate_csv(output.join("results.csv"), CorpusSearch::ExportWriter::RESULT_COLUMNS)
      validate_csv(output.join("flashcards.csv"), CorpusSearch::ExportWriter::FLASHCARD_COLUMNS)
      validate_csv(output.join("document_counts.csv"), CorpusSearch::AnalysisDatasetWriter::COLUMNS)
      validate_csv(output.join("analysis_occurrences.csv"), CorpusSearch::ExportWriter::ANALYSIS_OCCURRENCE_COLUMNS)
      validate_checksums(output)
      validate_figures(analysis.join("figures"), report)
      validate_zip(prepared.zip_path, output)
      validate_frozen_record(prepared, output)
      true
    end

    def validate_output_dir!(output, zip_path: nil)
      output = Pathname(output)
      @audit.file("cross-audit metadata", output.join("metadata.json"), minimum_bytes: 1)
      validate_json(output.join("metadata.json"))
      validate_checksums(output)
      report = validate_json(output.join("analysis", "standard", "analysis_report.json"))
      validate_figures(output.join("analysis", "standard", "figures"), report)
      validate_zip(zip_path || Dir[output.join("corpus_search_*.zip").to_s].first, output)
    end

    private

    def validate_json(path)
      parsed = nil
      @audit.check("valid JSON #{path.basename}", expected: "parseable JSON", actual: path.to_s) do
        parsed = JSON.parse(path.read(encoding: "UTF-8"))
        parsed.is_a?(Hash) || parsed.is_a?(Array)
      end
      parsed
    end

    def validate_csv(path, expected_headers = nil)
      rows = nil
      @audit.check("valid CSV #{path.basename}", expected: "parseable CSV", actual: path.to_s) do
        rows = CSV.read(path, headers: true, encoding: "bom|utf-8")
        true
      end
      return unless rows

      @audit.equal("CSV headers #{path.basename}", expected_headers, rows.headers) if expected_headers
      @audit.metric("rows_#{path.basename(".csv")}", rows.length)
      rows
    end

    def validate_checksums(output)
      path = output.join("checksums.sha256")
      lines = path.file? ? path.readlines(chomp: true) : []
      @audit.check("checksums file contains entries", expected: "> 0", actual: lines.length) { lines.any? }
      lines.each do |line|
        digest, relative = line.split(/\s{2,}/, 2)
        target = relative && output.join(relative)
        @audit.check("checksum #{relative}", expected: digest, actual: target&.file? ? Digest::SHA256.file(target).hexdigest : "missing") do
          target&.file? && Digest::SHA256.file(target).hexdigest == digest
        end
      end
    end

    def validate_figures(directory, report)
      charts = Array(report && report["charts"])
      charts.each do |chart|
        svg = directory.parent.join(chart["svg"].to_s)
        png = directory.parent.join(chart["png"].to_s)
        @audit.check("SVG #{svg.basename} has an svg root", expected: "<svg", actual: svg.to_s) do
          svg.file? && svg.size.positive? && svg.read(encoding: "UTF-8").include?("<svg")
        end
        @audit.check("PNG #{png.basename} has a valid signature and dimensions", expected: "PNG width/height > 0", actual: png.to_s) do
          valid_png?(png)
        end
      end
      @audit.metric("chart_count", charts.length)
    end

    def valid_png?(path)
      return false unless path&.file? && path.size >= 24

      bytes = path.binread(24)
      return false unless bytes.start_with?("\x89PNG\r\n\x1A\n".b)

      width, height = bytes.byteslice(16, 8).unpack("NN")
      width.positive? && height.positive?
    end

    def validate_zip(zip_path, output)
      path = Pathname(zip_path.to_s)
      names = []
      @audit.check("ZIP opens cleanly", expected: "valid ZIP", actual: path.to_s) do
        Zip::File.open(path) { |zip| names = zip.entries.map(&:name) }
        true
      end
      expected = Dir.glob(output.join("**", "*").to_s, File::FNM_DOTMATCH).filter_map do |entry|
        candidate = Pathname(entry)
        next unless candidate.file?
        next if candidate == path

        candidate.relative_path_from(output).to_s
      end.sort
      @audit.equal("ZIP member list matches output directory", expected, names.sort)
    end

    def validate_frozen_record(prepared, output)
      record = prepared.frozen_record
      @audit.check("frozen record is readable", expected: true, actual: record.class.name) { record.is_a?(Hash) }
      return unless record.is_a?(Hash)

      listed = Array(record["artifacts"])
      @audit.check("frozen record lists artefacts", expected: "> 0", actual: listed.length) { listed.any? }
      listed.each do |row|
        path = Pathname(row["path"].to_s)
        path = output.join(row["path"].to_s) unless path.absolute?
        next unless path.file?
        next unless row["sha256"]

        @audit.equal("frozen artefact digest #{row['path']}", row["sha256"], Digest::SHA256.file(path).hexdigest)
      end
    end
  end
end
