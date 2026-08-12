# frozen_string_literal: true

# Read-only performance sweep for the Fanya Hanwen Corpus viewer.
#
# Run from viewer/ with:
#   bin/rails runner script/performance_sweep.rb -- --mode all
#
# The script does not mutate application data. It exercises GET requests only.
# Results are written incrementally under tmp/performance_sweep/ so a terminated
# run can be resumed. Ctrl+C is intentionally never swallowed by the harness.

require "cgi"
require "csv"
require "digest/sha1"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "set"
require "timeout"

module PerformanceSweep
  VERSION = 2

  Scenario = Data.define(:id, :category, :label, :method, :path, :params) do
    def to_h
      {
        id: id,
        category: category,
        label: label,
        method: method,
        path: path,
        params: params
      }
    end
  end

  module Paths
    module_function

    def escape_segment(value)
      ERB::Util.url_encode(value.to_s)
    end

    def join(prefix, *segments)
      encoded = segments.flatten.compact.map { |segment| escape_segment(segment) }
      ([prefix.sub(%r{/+\z}, "")] + encoded).join("/")
    end
  end

  class Options
    attr_reader :mode, :output, :resume, :repeats, :timeout_seconds,
      :profile_count, :profile_min_ms, :limit, :only_categories,
      :skip_categories, :profile_scenario_ids

    def initialize(argv)
      @mode = "all"
      @output = nil
      @resume = true
      @repeats = 1
      @timeout_seconds = 120
      @profile_count = 30
      @profile_min_ms = 250.0
      @limit = nil
      @only_categories = []
      @skip_categories = []
      @profile_scenario_ids = []

      OptionParser.new do |parser|
        parser.banner = "Usage: bin/rails runner script/performance_sweep.rb -- [options]"

        parser.on("--mode MODE", %w[all sweep profile], "all, sweep, or profile") { |v| @mode = v }
        parser.on("--output DIR", "report directory (default: tmp/performance_sweep/<timestamp>)") { |v| @output = v }
        parser.on("--[no-]resume", "skip scenarios already present in requests.csv (default: resume)") { |v| @resume = v }
        parser.on("--repeats N", Integer, "repeat each scenario N times (default: 1)") { |v| @repeats = [v, 1].max }
        parser.on("--timeout SECONDS", Integer, "per-request timeout (default: 120)") { |v| @timeout_seconds = [v, 1].max }
        parser.on("--profile-count N", Integer, "profile N slowest scenarios after sweep (default: 30)") { |v| @profile_count = [v, 0].max }
        parser.on("--profile-min-ms MS", Float, "only auto-profile requests at least this slow (default: 250)") { |v| @profile_min_ms = [v, 0.0].max }
        parser.on("--profile-id ID", "profile this scenario id (repeatable)") { |v| @profile_scenario_ids << v }
        parser.on("--limit N", Integer, "stop after N generated scenarios (diagnostic/test use)") { |v| @limit = [v, 1].max }
        parser.on("--only CATEGORY", "only this category (repeatable)") { |v| @only_categories << v }
        parser.on("--skip CATEGORY", "skip this category (repeatable)") { |v| @skip_categories << v }
        parser.on("-h", "--help", "show this help") do
          puts parser
          exit 0
        end
      end.parse!(argv)
    end
  end

  class Report
    REQUEST_HEADERS = %w[
      scenario_id repeat category label method path params status
      wall_ms cpu_ms controller_ms view_ms db_ms sql_ms sql_queries
      templates partials collections allocations rss_before_kb rss_after_kb
      response_bytes location exception_class exception_message timestamp_utc
    ].freeze

    attr_reader :root

    def initialize(root:, resume:)
      @root = Pathname(root)
      FileUtils.mkdir_p(@root)
      FileUtils.mkdir_p(@root.join("profiles"))
      @requests_path = @root.join("requests.csv")
      @scenarios_path = @root.join("scenarios.jsonl")
      @run_path = @root.join("run.json")
      @resume = resume
      ensure_requests_header!
      @known_scenarios = load_known_scenarios
      @completed = resume ? load_completed : Set.new
    end

    def write_run_metadata(data)
      @run_path.write(JSON.pretty_generate(data) + "\n", mode: "w", encoding: "UTF-8")
    end

    def register_scenario(scenario)
      return if @known_scenarios.include?(scenario.id)

      File.open(@scenarios_path, "a:UTF-8") { |io| io.puts(JSON.generate(scenario.to_h)) }
      @known_scenarios << scenario.id
    end

    def completed?(scenario_id, repeat)
      @completed.include?([scenario_id, repeat])
    end

    def append_request(row)
      CSV.open(@requests_path, "a", encoding: "UTF-8") do |csv|
        csv << REQUEST_HEADERS.map { |header| row[header.to_sym] }
      end
      @completed << [row.fetch(:scenario_id), row.fetch(:repeat).to_i]
    end

    def request_rows
      return [] unless @requests_path.file?

      CSV.read(@requests_path, headers: true, encoding: "UTF-8").map(&:to_h)
    end

    def scenarios_by_id
      return {} unless @scenarios_path.file?

      @scenarios_path.each_line.with_object({}) do |line, out|
        next if line.strip.empty?
        row = JSON.parse(line)
        out[row.fetch("id")] = row
      end
    end

    def profile_path(scenario_id)
      @root.join("profiles", "#{scenario_id}.txt")
    end

    def summary_path
      @root.join("summary.txt")
    end

    private

    def ensure_requests_header!
      return if @requests_path.file? && @requests_path.size.positive?

      CSV.open(@requests_path, "w", encoding: "UTF-8") { |csv| csv << REQUEST_HEADERS }
    end

    def load_known_scenarios
      return Set.new unless @scenarios_path.file?

      @scenarios_path.each_line.with_object(Set.new) do |line, ids|
        next if line.strip.empty?
        ids << JSON.parse(line).fetch("id")
      rescue JSON::ParserError, KeyError
        next
      end
    end

    def load_completed
      return Set.new unless @requests_path.file?

      CSV.foreach(@requests_path, headers: true, encoding: "UTF-8").with_object(Set.new) do |row, set|
        id = row["scenario_id"]
        repeat = row["repeat"].to_i
        set << [id, repeat] if id.present?
      end
    rescue CSV::MalformedCSVError
      warn "[performance_sweep] requests.csv ended with an incomplete row; continuing with readable rows"
      Set.new
    end
  end

  class NotificationCollector
    attr_reader :sql_ms, :sql_queries, :templates, :partials, :collections,
      :controller_ms, :view_ms, :db_ms, :sql_details

    def initialize
      @active = false
      reset!
      install!
    end

    def start!
      reset!
      @active = true
    end

    def stop!
      @active = false
    end

    private

    def reset!
      @sql_ms = 0.0
      @sql_queries = 0
      @templates = 0
      @partials = 0
      @collections = 0
      @controller_ms = nil
      @view_ms = nil
      @db_ms = nil
      @sql_details = Hash.new { |hash, key| hash[key] = { count: 0, ms: 0.0 } }
    end

    def install!
      ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        next unless @active
        event = ActiveSupport::Notifications::Event.new(*args)
        payload = event.payload
        next if payload[:name].to_s == "SCHEMA"
        next if payload[:cached]

        duration = event.duration.to_f
        @sql_ms += duration
        @sql_queries += 1
        normalized = payload[:sql].to_s.gsub(/\s+/, " ").strip
        normalized = normalized[0, 1_000]
        bucket = @sql_details[normalized]
        bucket[:count] += 1
        bucket[:ms] += duration
      end

      ActiveSupport::Notifications.subscribe("render_template.action_view") do |*args|
        next unless @active
        @templates += 1
      end

      ActiveSupport::Notifications.subscribe("render_partial.action_view") do |*args|
        next unless @active
        @partials += 1
      end

      ActiveSupport::Notifications.subscribe("render_collection.action_view") do |*args|
        next unless @active
        @collections += 1
      end

      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        next unless @active
        event = ActiveSupport::Notifications::Event.new(*args)
        payload = event.payload
        @controller_ms = event.duration.to_f
        @view_ms = payload[:view_runtime]&.to_f
        @db_ms = payload[:db_runtime]&.to_f
      end
    end
  end

  class AppTraceProfiler
    MethodStat = Struct.new(:calls, :inclusive, keyword_init: true)
    LineStat = Struct.new(:hits, :wall, keyword_init: true)

    attr_reader :methods, :lines

    def initialize
      root = Rails.root.to_s
      @prefixes = [File.join(root, "app") + File::SEPARATOR, File.join(root, "lib") + File::SEPARATOR]
      @methods = Hash.new { |h, k| h[k] = MethodStat.new(calls: 0, inclusive: 0.0) }
      @lines = Hash.new { |h, k| h[k] = LineStat.new(hits: 0, wall: 0.0) }
      @stack = []
      @last_line_key = nil
      @last_line_at = nil
      @trace = nil
    end

    def start!
      @trace = TracePoint.new(:call, :return, :line) do |tp|
        next unless app_path?(tp.path)
        now = monotonic

        if @last_line_key && @last_line_at
          @lines[@last_line_key].wall += now - @last_line_at
          @last_line_at = now
        end

        case tp.event
        when :call
          key = method_key(tp)
          stat = @methods[key]
          stat.calls += 1
          @stack << [key, now]
        when :return
          key = method_key(tp)
          index = @stack.rindex { |entry| entry[0] == key }
          if index
            method_key_value, started = @stack.delete_at(index)
            @methods[method_key_value].inclusive += now - started
          end
        when :line
          @last_line_key = line_key(tp)
          @last_line_at = now
          @lines[@last_line_key].hits += 1
        end
      end
      @trace.enable
    end

    def stop!
      now = monotonic
      if @last_line_key && @last_line_at
        @lines[@last_line_key].wall += now - @last_line_at
      end
      @trace&.disable
      @trace = nil
    end

    def top_methods(limit = 80)
      @methods.sort_by { |_key, stat| -stat.inclusive }.first(limit)
    end

    def top_lines(limit = 120)
      @lines.sort_by { |_key, stat| -stat.wall }.first(limit)
    end

    private

    def app_path?(path)
      @prefixes.any? { |prefix| path.to_s.start_with?(prefix) }
    end

    def method_key(tp)
      relative = Pathname(tp.path).relative_path_from(Rails.root).to_s
      "#{relative}:#{tp.lineno} #{tp.defined_class}##{tp.method_id}"
    rescue ArgumentError
      "#{tp.path}:#{tp.lineno} #{tp.defined_class}##{tp.method_id}"
    end

    def line_key(tp)
      relative = Pathname(tp.path).relative_path_from(Rails.root).to_s
      "#{relative}:#{tp.lineno} #{tp.method_id}"
    rescue ArgumentError
      "#{tp.path}:#{tp.lineno} #{tp.method_id}"
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class ScenarioBuilder
    SAFE_STATIC_SKIP_PREFIXES = %w[
      /rails /assets /packs /cable /up
    ].freeze

    SAFE_STATIC_SKIP_PATHS = %w[
      /tickets /tickets/login /moderator_tokens
      /textbook/editor /textbook/editor/new
    ].freeze

    attr_reader :categories

    def initialize(only_categories:, skip_categories:, report_root:)
      @only = only_categories.to_set
      @skip = skip_categories.to_set
      @report_root = Pathname(report_root)
      @seen = Set.new
      @categories = Hash.new(0)
    end

    def each
      return enum_for(:each) unless block_given?

      generators = [
        [:static_get, method(:static_get_scenarios)],
        [:corpus, method(:corpus_scenarios)],
        [:characters, method(:character_scenarios)],
        [:dictionary, method(:dictionary_scenarios)],
        [:grammar, method(:grammar_scenarios)],
        [:atlas, method(:atlas_scenarios)],
        [:textbook, method(:textbook_scenarios)],
        [:bounded_queries, method(:bounded_query_scenarios)]
      ]

      generators.each do |category, generator|
        next unless include_category?(category.to_s)
        generator.call do |scenario|
          next if @seen.include?(scenario.id)
          @seen << scenario.id
          @categories[scenario.category] += 1
          yield scenario
        end
      rescue StandardError => e
        warn "[performance_sweep] scenario generator #{category} failed: #{e.class}: #{e.message}"
      end
    end

    private

    def include_category?(category)
      return false if @skip.include?(category)
      return true if @only.empty?
      @only.include?(category)
    end

    def scenario(category:, label:, path:, params: {})
      method = "GET"
      normalized_params = params.to_h.transform_keys(&:to_s).sort.to_h
      digest_source = JSON.generate([method, path, normalized_params])
      id = Digest::SHA1.hexdigest(digest_source)[0, 16]
      Scenario.new(
        id: id,
        category: category.to_s,
        label: label.to_s,
        method: method,
        path: path.to_s,
        params: normalized_params
      )
    end

    def static_get_scenarios
      Rails.application.routes.routes.each do |route|
        verb = route.verb.to_s
        next unless verb.include?("GET")

        required = Array(route.required_parts).map(&:to_s) - ["format"]
        next if required.any?

        raw = route.path.spec.to_s
        path = raw.sub(/\(\.\:format\)\z/, "")
        next if path.include?(":") || path.include?("*") || path.include?("(")
        next if SAFE_STATIC_SKIP_PREFIXES.any? { |prefix| path.start_with?(prefix) }
        next if SAFE_STATIC_SKIP_PATHS.include?(path)

        controller = route.defaults[:controller]
        action = route.defaults[:action]
        label = [controller, action].compact.join("#")
        yield scenario(category: :static_get, label: label.presence || path, path: path)
      end
    end

    # The corpus can contain tens of thousands of works, but almost all of them
    # exercise the same controller/service/view code. Rendering every file is
    # therefore expensive repetition, not useful coverage.
    #
    # Instead we make one cheap filesystem inventory of the entire corpus, then
    # render a deliberately small set of representative/extreme shapes:
    #   - smallest / median / p95 / largest text
    #   - deepest text path
    #   - directories with smallest / median / p95 / largest fan-out
    #   - deepest directory
    #   - work folders with largest metadata, most documents, largest byte total
    #   - examples containing annotation/translation companion structures
    #
    # The complete structural scan is written to corpus_inventory.csv so odd
    # corpus shapes are still visible without paying for a Rails render per work.
    def corpus_scenarios
      root = Rails.configuration.x.corpus_root.to_s
      return if root.blank? || !Dir.exist?(root)

      root_real = File.realpath(root)
      root_path = Pathname(root_real)
      directories = []
      files = []
      works = []
      stack = [root_real]

      until stack.empty?
        abs = stack.pop
        rel = relative_corpus_path(abs, root_path)
        visible = Dir.children(abs).reject { |name| name.start_with?(".") }
        child_dirs = []
        txt_files = []

        visible.each do |name|
          full = File.join(abs, name)
          if File.directory?(full)
            child_dirs << full
            stack << full
          elsif name.downcase.end_with?(".txt")
            txt_files << full
            files << corpus_file_inventory(full, root_path)
          end
        end

        metadata_path = File.join(abs, "metadata.json")
        metadata_bytes = File.file?(metadata_path) ? File.size(metadata_path) : 0
        txt_bytes = txt_files.sum { |file| File.size(file) rescue 0 }
        flags = corpus_structure_flags(rel, visible)

        row = {
          kind: "directory",
          path: rel,
          bytes: txt_bytes,
          depth: corpus_depth(rel),
          child_count: visible.length,
          directory_count: child_dirs.length,
          txt_count: txt_files.length,
          metadata_bytes: metadata_bytes,
          flags: flags.join(";")
        }
        directories << row
        works << row if metadata_bytes.positive?
      end

      selected = {}
      select_corpus_extremes!(selected, directories, files, works)
      write_corpus_inventory(directories, files, selected)

      selected.values.sort_by { |entry| [entry.fetch(:kind), entry.fetch(:path)] }.each do |entry|
        rel = entry.fetch(:path)
        path = rel.blank? ? "/corpus_viewer" : corpus_url(rel)
        reasons = Array(entry[:selected_reasons]).join(", ")
        label_kind = entry.fetch(:kind) == "file" ? "file" : "directory"
        yield scenario(
          category: :corpus,
          label: "#{label_kind} #{rel.presence || '(root)'} [#{reasons}]",
          path: path
        )
      end
    end

    def relative_corpus_path(abs, root_path)
      rel = Pathname(abs).relative_path_from(root_path).to_s.tr("\\", "/")
      rel == "." ? "" : rel
    end

    def corpus_depth(rel)
      rel.blank? ? 0 : rel.split("/").length
    end

    def corpus_file_inventory(full, root_path)
      rel = relative_corpus_path(full, root_path)
      {
        kind: "file",
        path: rel,
        bytes: File.size(full),
        depth: corpus_depth(rel),
        child_count: nil,
        directory_count: nil,
        txt_count: nil,
        metadata_bytes: nil,
        flags: corpus_path_flags(rel).join(";")
      }
    rescue SystemCallError
      {
        kind: "file", path: rel.to_s, bytes: 0, depth: corpus_depth(rel.to_s),
        child_count: nil, directory_count: nil, txt_count: nil, metadata_bytes: nil, flags: "stat_error"
      }
    end

    def corpus_structure_flags(rel, visible_entries)
      flags = corpus_path_flags(rel)
      names = visible_entries.map(&:downcase)
      flags << "has_metadata" if names.include?("metadata.json")
      flags << "has_translation_dir" if names.include?("translation")
      %w[kanbun hanmun hanvan].each do |name|
        flags << "has_#{name}_dir" if names.include?(name)
      end
      flags.uniq
    end

    def corpus_path_flags(rel)
      value = "/#{rel.downcase}/"
      flags = []
      flags << "translation" if value.include?("/translation/")
      %w[kanbun hanmun hanvan].each { |name| flags << name if value.include?("/#{name}/") }
      flags
    end

    def select_corpus_extremes!(selected, directories, files, works)
      add_selected!(selected, directories.find { |row| row[:path].blank? }, "corpus root")

      select_ranked!(selected, files, :bytes, "text bytes")
      select_ranked!(selected, files, :depth, "text path depth")
      select_ranked!(selected, directories, :child_count, "directory fan-out")
      select_ranked!(selected, directories, :depth, "directory depth")
      select_ranked!(selected, works, :metadata_bytes, "work metadata bytes")
      select_ranked!(selected, works, :txt_count, "work document count")
      select_ranked!(selected, works, :bytes, "work direct text bytes")

      # Ensure each structural feature is represented if it exists.
      feature_names = %w[translation kanbun hanmun hanvan has_translation_dir has_kanbun_dir has_hanmun_dir has_hanvan_dir]
      feature_names.each do |feature|
        candidates = (directories + files).select do |row|
          row[:flags].to_s.split(";").include?(feature)
        end
        next if candidates.empty?
        candidate = candidates.max_by { |row| [row[:bytes].to_i, row[:depth].to_i] }
        add_selected!(selected, candidate, "feature #{feature}")
      end
    end

    def select_ranked!(selected, rows, key, label)
      usable = rows.select { |row| !row[key].nil? }.sort_by { |row| row[key].to_i }
      return if usable.empty?

      {
        "minimum" => usable.first,
        "median" => usable[((usable.length - 1) * 0.50).round],
        "p95" => usable[((usable.length - 1) * 0.95).round],
        "maximum" => usable.last
      }.each do |rank, row|
        add_selected!(selected, row, "#{label} #{rank}")
      end
    end

    def add_selected!(selected, row, reason)
      return unless row
      key = [row.fetch(:kind), row.fetch(:path)]
      copy = selected[key] ||= row.dup.merge(selected_reasons: [])
      copy[:selected_reasons] << reason unless copy[:selected_reasons].include?(reason)
    end

    def write_corpus_inventory(directories, files, selected)
      path = @report_root.join("corpus_inventory.csv")
      selected_reasons = selected.transform_values { |row| Array(row[:selected_reasons]).join("; ") }
      headers = %w[kind path bytes depth child_count directory_count txt_count metadata_bytes flags selected_reasons]

      CSV.open(path, "w", encoding: "UTF-8") do |csv|
        csv << headers
        (directories + files).sort_by { |row| [row[:kind], row[:path]] }.each do |row|
          reasons = selected_reasons[[row[:kind], row[:path]]].to_s
          csv << headers.map do |header|
            header == "selected_reasons" ? reasons : row[header.to_sym]
          end
        end
      end

      puts "[performance_sweep] corpus inventory: #{directories.length} directories, #{files.length} text files; #{selected.length} representative renders"
    end

    def corpus_url(rel)
      segments = rel.split("/").map { |segment| Paths.escape_segment(segment) }
      "/corpus_viewer/#{segments.join('/')}"
    end

    def character_scenarios
      return unless defined?(CharacterCodepoint)

      CharacterCodepoint.select(:id, :codepoint).find_each(batch_size: 2_000) do |character|
        cp = character.codepoint
        next unless cp
        identifier = format("U+%04X", cp)
        encoded = Paths.escape_segment(identifier)
        yield scenario(category: :characters, label: "character #{identifier}", path: "/characters/#{encoded}")
        yield scenario(category: :characters, label: "character preview #{identifier}", path: "/characters/#{encoded}/preview")
      end
    end

    def dictionary_scenarios
      return unless defined?(DictionaryWork)

      DictionaryWork.select(:id, :corpus_work_id).find_each do |work|
        work_id = work.corpus_work_id
        next if work_id.blank?
        yield scenario(category: :dictionary, label: "dictionary work #{work_id}", path: Paths.join("/dictionary/catalogue", work_id))
      end

      if defined?(DictionarySection)
        DictionarySection.includes(:dictionary_work).find_each do |section|
          work_id = section.dictionary_work&.corpus_work_id
          sequence = section.sequence_number
          next if work_id.blank? || sequence.blank?
          base = Paths.join("/dictionary/catalogue", work_id, "sections", sequence)
          yield scenario(category: :dictionary, label: "dictionary section #{work_id}/#{sequence}", path: base)
          yield scenario(category: :dictionary, label: "dictionary section entries #{work_id}/#{sequence}", path: "#{base}/entries")
        end
      end

      if defined?(DictionaryEntry)
        DictionaryEntry.includes(:dictionary_work).find_each(batch_size: 2_000) do |entry|
          work_id = entry.dictionary_work&.corpus_work_id
          sequence = entry.sequence_number
          next if work_id.blank? || sequence.blank?
          yield scenario(
            category: :dictionary,
            label: "dictionary entry #{work_id}/#{sequence}",
            path: Paths.join("/dictionary/catalogue", work_id, "entries", sequence)
          )
        end
      end
    end

    def grammar_scenarios
      return unless defined?(Grammar::EntryStore)

      store = Grammar::EntryStore.default
      Array(store.all).each do |entry|
        next if entry.id.blank?
        yield scenario(category: :grammar, label: "grammar #{entry.id}", path: Paths.join("/grammar", entry.id))
        yield scenario(category: :grammar, label: "grammar template #{entry.id}", path: Paths.join("/grammar", entry.id, "template"))
      end
    end

    def atlas_scenarios
      return unless defined?(Atlas::EntryStore)

      store = Atlas::EntryStore.default
      entries = if store.respond_to?(:all)
                  store.all
                elsif store.respond_to?(:entries)
                  store.entries
                else
                  []
                end
      Array(entries).each do |entry|
        next if entry.id.blank?
        yield scenario(category: :atlas, label: "atlas #{entry.id}", path: Paths.join("/atlas", entry.id))
        yield scenario(category: :atlas, label: "atlas template #{entry.id}", path: Paths.join("/atlas", entry.id, "template"))
      end

      return unless defined?(Atlas::Catalogue)
      catalogue = Atlas::Catalogue.default
      Array(catalogue.macro_regions).each do |macro|
        macro_id = value_from(macro, :id, "id")
        next if macro_id.blank?
        yield scenario(category: :atlas, label: "atlas macro region #{macro_id}", path: "/atlas", params: { macro_region: macro_id })
        Array(catalogue.periods_for(macro_id)).each do |period|
          period_id = value_from(period, :id, "id")
          next if period_id.blank?
          yield scenario(
            category: :atlas,
            label: "atlas period #{macro_id}/#{period_id}",
            path: "/atlas",
            params: { macro_region: macro_id, period: period_id }
          )
        end
      end
    end

    def textbook_scenarios
      return unless defined?(Textbook::LessonStore)

      Array(Textbook::LessonStore.all).each do |lesson|
        slug = value_from(lesson, :slug, "slug")
        next if slug.blank?
        yield scenario(category: :textbook, label: "textbook #{slug}", path: Paths.join("/textbook", slug))
      end
    end

    # Arbitrary search strings have an infinite input space. These probes cover
    # deterministic boundary shapes while the finite object IDs above are exhaustive.
    def bounded_query_scenarios
      probes = {
        "/characters" => [
          {},
          { query: "一" },
          { query: "U+4E00" },
          { query: "10FFFF" },
          { query: "不存在" }
        ],
        "/characters/structure" => [
          {},
          { q: "⿰木木" },
          { q: "木" },
          { q: "⿱" },
          { q: "不存在" }
        ],
        "/corpus/search" => [
          {},
          { q: "之" },
          { q: "天地" },
          { q: "不存在於語料庫之測試字串" }
        ],
        "/atlas" => [
          {},
          { q: "中國" },
          { q: "日本" },
          { q: "does-not-exist" }
        ],
        "/grammar" => [
          {},
          { sort: "radical" },
          { sort: "importance" },
          { needed: "1" }
        ]
      }

      probes.each do |path, parameter_sets|
        parameter_sets.each_with_index do |params, index|
          yield scenario(category: :bounded_queries, label: "#{path} probe #{index + 1}", path: path, params: params)
        end
      end
    end

    def value_from(object, method_name, hash_key)
      return object.public_send(method_name) if object.respond_to?(method_name)
      return object[hash_key] if object.respond_to?(:[]) && object[hash_key].present?
      nil
    end
  end

  class Runner
    def initialize(options)
      @options = options
      @report = Report.new(root: report_root, resume: options.resume)
      @collector = NotificationCollector.new
      @session = ActionDispatch::Integration::Session.new(Rails.application)
      @session.host! "localhost"
    end

    def run
      @report.write_run_metadata(run_metadata)
      sweep if %w[all sweep].include?(@options.mode)
      profile if %w[all profile].include?(@options.mode)
      write_summary
      puts "[performance_sweep] report: #{@report.root}"
    end

    private

    def report_root
      return Rails.root.join(@options.output) if @options.output.present? && !Pathname(@options.output).absolute?
      return Pathname(@options.output) if @options.output.present?

      Rails.root.join("tmp", "performance_sweep", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
    end

    def run_metadata
      {
        version: VERSION,
        started_at_utc: Time.now.utc.iso8601,
        rails_env: Rails.env,
        rails_version: Rails.version,
        ruby_version: RUBY_VERSION,
        ruby_platform: RUBY_PLATFORM,
        pid: Process.pid,
        corpus_root: Rails.configuration.x.corpus_root.to_s,
        git_head: git_head,
        options: {
          mode: @options.mode,
          resume: @options.resume,
          repeats: @options.repeats,
          timeout_seconds: @options.timeout_seconds,
          profile_count: @options.profile_count,
          profile_min_ms: @options.profile_min_ms,
          limit: @options.limit,
          only_categories: @options.only_categories,
          skip_categories: @options.skip_categories
        }
      }
    end

    def git_head
      head = Rails.root.join("..", ".git", "HEAD")
      return nil unless head.file?
      value = head.read.strip
      if value.start_with?("ref: ")
        ref_path = Rails.root.join("..", ".git", value.delete_prefix("ref: "))
        return ref_path.read.strip if ref_path.file?
      end
      value
    rescue StandardError
      nil
    end

    def sweep
      builder = ScenarioBuilder.new(
        only_categories: @options.only_categories,
        skip_categories: @options.skip_categories,
        report_root: @report.root
      )

      generated = 0
      builder.each do |scenario|
        generated += 1
        break if @options.limit && generated > @options.limit

        @report.register_scenario(scenario)
        @options.repeats.times do |repeat_index|
          repeat = repeat_index + 1
          next if @report.completed?(scenario.id, repeat)

          row = execute_scenario(scenario, repeat: repeat)
          @report.append_request(row)
          print_progress(generated, scenario, row)
        end
      end
    end

    def execute_scenario(scenario, repeat:, trace: nil)
      gc_before = GC.stat
      rss_before = rss_kb
      wall_started = monotonic
      cpu_started = cpu_clock
      response = nil
      exception = nil

      @collector.start!
      trace&.start!
      begin
        Timeout.timeout(@options.timeout_seconds) do
          @session.get(scenario.path, params: scenario.params)
          response = @session.response
        end
      rescue StandardError => e
        # Intentionally do NOT rescue Exception/Interrupt/SystemExit. Ctrl+C must
        # terminate the sweep immediately instead of being recorded as a failed
        # scenario and moving on to the next request.
        exception = e
      ensure
        trace&.stop!
        @collector.stop!
      end

      wall_ms = (monotonic - wall_started) * 1_000.0
      cpu_ms = (cpu_clock - cpu_started) * 1_000.0
      gc_after = GC.stat
      rss_after = rss_kb

      {
        scenario_id: scenario.id,
        repeat: repeat,
        category: scenario.category,
        label: scenario.label,
        method: scenario.method,
        path: scenario.path,
        params: JSON.generate(scenario.params),
        status: response&.status,
        wall_ms: round_ms(wall_ms),
        cpu_ms: round_ms(cpu_ms),
        controller_ms: round_ms(@collector.controller_ms),
        view_ms: round_ms(@collector.view_ms),
        db_ms: round_ms(@collector.db_ms),
        sql_ms: round_ms(@collector.sql_ms),
        sql_queries: @collector.sql_queries,
        templates: @collector.templates,
        partials: @collector.partials,
        collections: @collector.collections,
        allocations: gc_after[:total_allocated_objects] - gc_before[:total_allocated_objects],
        rss_before_kb: rss_before,
        rss_after_kb: rss_after,
        response_bytes: response&.body&.bytesize,
        location: response&.headers&.fetch("location", nil),
        exception_class: exception&.class&.name,
        exception_message: exception&.message.to_s[0, 2_000],
        timestamp_utc: Time.now.utc.iso8601
      }
    end

    def profile
      scenarios = @report.scenarios_by_id
      ids = if @options.profile_scenario_ids.any?
              @options.profile_scenario_ids
            else
              slowest_ids
            end

      ids.uniq.each_with_index do |id, index|
        raw = scenarios[id]
        next unless raw

        scenario = Scenario.new(
          id: raw.fetch("id"),
          category: raw.fetch("category"),
          label: raw.fetch("label"),
          method: raw.fetch("method"),
          path: raw.fetch("path"),
          params: raw.fetch("params", {})
        )
        puts "[performance_sweep] profiling #{index + 1}/#{ids.length}: #{scenario.label}"
        profiler = AppTraceProfiler.new
        row = execute_scenario(scenario, repeat: 0, trace: profiler)
        write_profile(scenario, row, profiler, @collector.sql_details)
      end
    end

    def slowest_ids
      best_by_id = {}
      @report.request_rows.each do |row|
        ms = row["wall_ms"].to_f
        next if ms < @options.profile_min_ms
        current = best_by_id[row["scenario_id"]]
        best_by_id[row["scenario_id"]] = row if current.nil? || ms > current["wall_ms"].to_f
      end
      best_by_id.values
        .sort_by { |row| -row["wall_ms"].to_f }
        .first(@options.profile_count)
        .map { |row| row["scenario_id"] }
    end

    def write_profile(scenario, row, profiler, sql_details)
      path = @report.profile_path(scenario.id)
      File.open(path, "w:UTF-8") do |io|
        io.puts "Fanya Hanwen performance profile"
        io.puts "scenario_id: #{scenario.id}"
        io.puts "category: #{scenario.category}"
        io.puts "label: #{scenario.label}"
        io.puts "request: #{scenario.method} #{scenario.path} #{JSON.generate(scenario.params)}"
        io.puts "status: #{row[:status]}"
        io.puts "wall_ms: #{row[:wall_ms]}"
        io.puts "cpu_ms: #{row[:cpu_ms]}"
        io.puts "controller_ms: #{row[:controller_ms]}"
        io.puts "view_ms: #{row[:view_ms]}"
        io.puts "db_ms: #{row[:db_ms]}"
        io.puts "sql_ms: #{row[:sql_ms]}"
        io.puts "sql_queries: #{row[:sql_queries]}"
        io.puts "allocations: #{row[:allocations]}"
        io.puts "exception: #{row[:exception_class]} #{row[:exception_message]}" if row[:exception_class].present?
        io.puts

        io.puts "TOP APPLICATION METHODS (inclusive wall time; tracing adds overhead)"
        io.puts "ms\tcalls\tlocation"
        profiler.top_methods.each do |key, stat|
          io.puts format("%.3f\t%d\t%s", stat.inclusive * 1_000.0, stat.calls, key)
        end
        io.puts

        io.puts "TOP APPLICATION LINES (time until next application line; tracing adds overhead)"
        io.puts "ms\thits\tlocation"
        profiler.top_lines.each do |key, stat|
          io.puts format("%.3f\t%d\t%s", stat.wall * 1_000.0, stat.hits, key)
        end
        io.puts

        io.puts "TOP SQL STATEMENTS"
        io.puts "ms\tcount\tsql"
        sql_details.sort_by { |_sql, stat| -stat[:ms] }.first(80).each do |sql, stat|
          io.puts format("%.3f\t%d\t%s", stat[:ms], stat[:count], sql)
        end
      end
    end

    def write_summary
      rows = @report.request_rows
      measured = rows.reject { |row| row["repeat"].to_i.zero? }
      slowest = measured.sort_by { |row| -row["wall_ms"].to_f }.first(100)
      errors = measured.select { |row| row["exception_class"].present? || row["status"].to_i >= 500 }
      by_category = measured.group_by { |row| row["category"] }

      File.open(@report.summary_path, "w:UTF-8") do |io|
        io.puts "Fanya Hanwen performance sweep summary"
        io.puts "generated request rows: #{measured.length}"
        io.puts "errors/timeouts: #{errors.length}"
        io.puts
        io.puts "CATEGORY SUMMARY"
        io.puts "category\trequests\tmedian_ms\tp95_ms\tmax_ms\tmean_queries"
        by_category.sort.each do |category, category_rows|
          times = category_rows.map { |row| row["wall_ms"].to_f }.sort
          queries = category_rows.map { |row| row["sql_queries"].to_i }
          io.puts [
            category,
            times.length,
            format("%.3f", percentile(times, 0.50)),
            format("%.3f", percentile(times, 0.95)),
            format("%.3f", times.max.to_f),
            format("%.2f", queries.sum.to_f / [queries.length, 1].max)
          ].join("\t")
        end
        io.puts
        io.puts "100 SLOWEST REQUESTS"
        io.puts "ms\tstatus\tqueries\tdb_ms\tview_ms\tcategory\tscenario_id\trequest"
        slowest.each do |row|
          io.puts [
            row["wall_ms"], row["status"], row["sql_queries"], row["db_ms"], row["view_ms"],
            row["category"], row["scenario_id"], "#{row['method']} #{row['path']} #{row['params']}"
          ].join("\t")
        end
        io.puts
        io.puts "ERRORS / TIMEOUTS"
        errors.each do |row|
          io.puts [row["scenario_id"], row["status"], row["exception_class"], row["exception_message"], row["path"]].join("\t")
        end
      end
    end

    def print_progress(number, scenario, row)
      puts format(
        "[%d] %-15s %9.3f ms  q=%-4d status=%-3s %s",
        number,
        scenario.category,
        row[:wall_ms].to_f,
        row[:sql_queries].to_i,
        row[:status] || row[:exception_class] || "?",
        scenario.path
      )
    end

    def percentile(sorted, fraction)
      return 0.0 if sorted.empty?
      index = ((sorted.length - 1) * fraction).round
      sorted.fetch(index)
    end

    def round_ms(value)
      value.nil? ? nil : value.to_f.round(3)
    end

    def rss_kb
      status = Pathname("/proc/#{Process.pid}/status")
      return nil unless status.file?
      line = status.each_line.find { |candidate| candidate.start_with?("VmRSS:") }
      line&.split&.at(1)&.to_i
    rescue StandardError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def cpu_clock
      Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    end
  end
end

options = PerformanceSweep::Options.new(ARGV)
PerformanceSweep::Runner.new(options).run
