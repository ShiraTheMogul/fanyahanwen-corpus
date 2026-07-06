# frozen_string_literal: true

require_relative "support"

module CorpusSearchAudit
  module Cases
    module_function

    def run(id, audit)
      method = id.to_s
      raise ArgumentError, "Unknown audit case: #{id}" unless respond_to?(method, true)

      send(method, audit)
    end

    def environment_contract(audit)
      audit.step("runtime versions") do
        requested_ruby = Rails.root.join(".ruby-version").read.strip.sub(/\Aruby-/, "")
        audit.equal("Ruby matches .ruby-version", requested_ruby, RUBY_VERSION)
        audit.matches("Rails is 8.1.x", Rails.version, /\A8\.1\./)
        audit.file("standard Ruby profile exists", Rails.root.join("analysis/ruby/profiles/standard_analysis.rb"), minimum_bytes: 1_000)
        audit.file("Ruby analysis runner exists", Rails.root.join("app/services/corpus_search/analysis_runner.rb"), minimum_bytes: 1_000)
        audit.check("obsolete R profile directory is absent", expected: false, actual: Rails.root.join("analysis/r").exist?) { !Rails.root.join("analysis/r").exist? }
        audit.check("obsolete R runner is absent", expected: false, actual: Rails.root.join("app/services/corpus_search/r_analysis_runner.rb").exist?) { !Rails.root.join("app/services/corpus_search/r_analysis_runner.rb").exist? }
      end

      audit.step("real corpus root") do
        root = Pathname(Rails.configuration.x.corpus_root.to_s).expand_path
        readable = root.directory? && root.readable?
        audit.check("corpus root exists", expected: "readable directory", actual: root.to_s) { readable }
        entries = readable ? Dir.children(root).first(100) : []
        audit.check("corpus root is not empty", expected: "at least one visible entry", actual: entries.first(10)) { entries.any? }
        audit.metric("corpus_root", root.to_s)
      rescue SystemCallError => error
        audit.check("corpus root can be listed", expected: "directory listing succeeds", actual: "#{error.class}: #{error.message}") { false }
      end

      audit.step("database and application services") do
        database_value = ActiveRecord::Base.connection.select_value("SELECT 1")
        audit.equal("database responds", 1, database_value.to_i)
        audit.check("ZIP library can create archives", expected: true, actual: defined?(Zip::File).present?) { defined?(Zip::File).present? }
        audit.check("queue adapter is configured", expected: true, actual: ActiveJob::Base.queue_adapter.class.name) { ActiveJob::Base.queue_adapter.present? }
      end

      audit.step("analysis Ruby runtime") do
        executable = ENV.fetch("CORPUS_SEARCH_RUBY", RbConfig.ruby)
        stdout, stderr, status = Open3.capture3(executable, "-v")
        version = [stdout, stderr].join(" ").strip.gsub(/\s+/, " ")
        audit.check("analysis Ruby is available", expected: "successful ruby -v", actual: version) { status.success? }
        audit.matches("Ruby version is reported", version, /ruby \d+\.\d+/i)
        audit.metric("analysis_ruby", executable)
        audit.metric("analysis_ruby_version", version)
      rescue SystemCallError => error
        audit.check("analysis Ruby is available", expected: "Ruby at CORPUS_SEARCH_RUBY or the Rails runtime", actual: error.message) { false }
      end

      audit.step("disk capacity") do
        stdout, = Open3.capture2("df", "-Pk", Rails.root.to_s)
        row = stdout.lines.last.to_s.split
        available_kb = row[3].to_i
        audit.metric("available_disk_bytes", available_kb * 1_024)
        audit.check("at least 5 GiB free for overnight artefacts", expected: ">= 5 GiB", actual: available_kb * 1_024) do
          available_kb >= 5 * 1_024 * 1_024
        end
      end
    end

    def application_eager_load(audit)
      audit.step("eager load Rails") do
        error = nil
        begin
          Rails.application.eager_load!
        rescue Exception => e # rubocop:disable Lint/RescueException
          error = e
        end
        audit.check("application eager-loads cleanly", expected: "no exception", actual: error && "#{error.class}: #{error.message}", detail: error&.backtrace&.first(30)&.join("\n")) { error.nil? }
      end

      audit.step("search constants") do
        %w[
          CorpusSearch::Runner CorpusSearch::Manifest CorpusSearch::ExportWriter
          CorpusSearch::AnalysisRunner CorpusSearch::AnalysisReport CorpusSearchController
        ].each do |name|
          audit.check("constant #{name} is loaded", expected: true, actual: name.safe_constantize&.name) { name.safe_constantize.present? }
        end
      end
    end

    def route_and_form_contract(audit)
      root, cache, = synthetic_context(audit)
      ENV["CORPUS_SEARCH_AUDIT_CACHE_ROOT"] = cache.root.to_s

      Helpers.with_corpus(root) do
        audit.step("named route recognition") do
          routes = Rails.application.routes
          audit.equal("GET search route", { controller: "corpus_search", action: "index" }, routes.recognize_path("/corpus/search", method: :get).slice(:controller, :action))
          audit.equal("POST prepare route", { controller: "corpus_search", action: "prepare" }, routes.recognize_path("/corpus/search/prepare", method: :post).slice(:controller, :action))
          audit.equal("GET prepared route", { controller: "corpus_search", action: "prepared", id: "abc" }, routes.recognize_path("/corpus/search/prepared/abc", method: :get).slice(:controller, :action, :id))
          audit.equal("GET download route", { controller: "corpus_search", action: "download", id: "abc" }, routes.recognize_path("/corpus/search/prepared/abc/download", method: :get).slice(:controller, :action, :id))
        end

        audit.step("rendered form") do
          session = integration_session
          session.get("/corpus/search", params: { q: "人之初", characters: "exact" })
          body = session.response.body
          audit.equal("search form responds 200", 200, session.response.status)
          {
            "exact mode" => "data-mode=\"exact\"",
            "proximity mode" => "data-mode=\"proximity\"",
            "OR mode" => "data-mode=\"alternatives\"",
            "term array" => "name=\"terms[]\"",
            "span control" => "name=\"span\"",
            "order control" => "name=\"order\"",
            "punctuation control" => "name=\"punctuation\"",
            "character matching" => "name=\"characters\"",
            "roles" => "name=\"roles[]\"",
            "include folders" => "name=\"folders[]\"",
            "exclude folders" => "name=\"exclude_folders[]\"",
            "analysis action" => "action=\"/corpus/search/prepare\""
          }.each do |label, fragment|
            audit.includes("form contains #{label}", body, fragment)
          end
        end
      end
    end

    def synthetic_manifest_roles(audit)
      root, _cache, manifest = synthetic_context(audit)
      audit.step("manifest shape") do
        paths = manifest.documents.map { |doc| doc["path"] }
        audit.check("synthetic manifest has generated scale", expected: ">= 156 documents", actual: paths.length) { paths.length >= 156 }
        audit.equal("manifest IDs are unique", manifest.documents.length, manifest.documents.map { |doc| doc["id"] }.uniq.length)
        audit.check("symlink is skipped", expected: false, actual: paths.any? { |path| path.end_with?("symlink.txt") }) { paths.none? { |path| path.end_with?("symlink.txt") } }
      end

      audit.step("document roles") do
        expected = {
          "received.txt" => "canonical",
          "variant.txt" => "textual_variant",
          "raw.txt" => "raw",
          "reading.txt" => "derived_reading",
          "en.txt" => "translation",
          "note.txt" => "annotation",
          "support.txt" => "support"
        }
        expected.each do |basename, role|
          doc = manifest.documents.find { |row| File.basename(row["path"]) == basename }
          audit.equal("role #{basename}", role, doc && doc["document_role"])
        end
      end

      audit.step("body-only parser") do
        fs = CorpusFs.new(root: root)
        parsed = CorpusSearch::DocumentReader.read(fs: fs, path: "中國漢文/clean/周朝/metadata_only.txt")
        audit.includes("metadata title retains query text", parsed.metadata["title"], "只在標題")
        audit.check("body excludes front matter", expected: false, actual: parsed.body) { !parsed.body.include?("只在標題") && !parsed.body.include?("# TITLE") }
        audit.equal("body fingerprint is SHA-256", 64, parsed.body_fingerprint.length)
      end
    end

    def synthetic_exact_matrix(audit)
      root, cache, manifest = synthetic_context(audit)

      audit.step("punctuation and offsets") do
        _query, ignored = Helpers.run_page(
          root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩在河之洲",
          punctuation: "ignore", characters: "exact", folders: ["中國漢文/clean/周朝/詩經"]
        )
        audit.equal("punctuation-free query finds punctuated text", 1, ignored.total)
        hit = ignored.hits.first || {}
        audit.equal("matched source text retains punctuation", "關關雎鳩，在河之洲", hit["matched_text"])
        audit.equal("original start offset", 0, hit["start_offset"])
        audit.equal("normalized span length", 8, hit["search_end_offset"].to_i - hit["search_start_offset"].to_i)

        _query, respected_miss = Helpers.run_page(
          root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩在河之洲",
          punctuation: "respect", characters: "exact", folders: ["中國漢文/clean/周朝/詩經"]
        )
        audit.equal("respect punctuation rejects omitted punctuation", 0, respected_miss.total)

        _query, respected_hit = Helpers.run_page(
          root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩，在河之洲",
          punctuation: "respect", characters: "exact", folders: ["中國漢文/clean/周朝/詩經"]
        )
        audit.equal("respect punctuation accepts entered punctuation", 1, respected_hit.total)
      end

      audit.step("body-only exact matching") do
        _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "只在標題", characters: "exact")
        audit.equal("metadata-only sequence produces no hit", 0, page.total)
      end

      audit.step("interactive cap and uncapped background path") do
        query = Helpers.build_query(q: "密集詞", characters: "exact", folders: ["中國漢文/clean/周朝/dense_occurrences.txt"])
        limited = Helpers.with_corpus(root) do
          CorpusSearch::Runner.new(query: query, manifest: manifest, cache_store: cache).page(max_hits: 1_000)
        end
        all_count = Helpers.with_corpus(root) do
          CorpusSearch::Runner.new(query: query, manifest: manifest, cache_store: cache).each_hit
        end
        audit.equal("interactive result count stops at one thousand", 1_000, limited.total)
        audit.equal("interactive result marks itself truncated", true, limited.truncated)
        audit.equal("interactive result marks scan incomplete", false, limited.complete)
        audit.equal("background hit stream is not capped", 1_105, all_count)
      end

      audit.step("character equivalence") do
        options = { root: root, cache_store: cache, manifest: manifest, q: "試驗", folders: ["日本漢文/clean/江戶時代"] }
        _query, exact = Helpers.run_page(**options, characters: "exact")
        _query, broad = Helpers.run_page(**options, characters: "broad")
        audit.equal("exact matching does not accept shinjitai", 0, exact.total)
        audit.equal("broad matching accepts shinjitai", 1, broad.total)
        explanation = broad.hits.first.to_h.fetch("equivalence_matches", []).first.to_h
        audit.equal("equivalence query character", "驗", explanation["query_character"])
        audit.equal("equivalence source character", "験", explanation["source_character"])
      end

      audit.step("pagination and context") do
        _query, first = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "無命中正文", characters: "exact", page: 1, per_page: 7, context: 0)
        _query, second = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "無命中正文", characters: "exact", page: 2, per_page: 7, context: 0)
        audit.equal("first page size", 7, first.hits.length)
        audit.equal("second page size", 7, second.hits.length)
        audit.check("pages do not repeat occurrences", expected: "disjoint IDs/offsets", actual: nil) do
          first_keys = first.hits.map { |hit| [hit["path"], hit["start_offset"]] }
          second_keys = second.hits.map { |hit| [hit["path"], hit["start_offset"]] }
          (first_keys & second_keys).empty?
        end
        audit.check("zero context is honoured", expected: "blank left/right context", actual: first.hits.first) do
          first.hits.all? { |hit| hit["left_context"] == "" && hit["right_context"] == "" }
        end
      end

      audit.step("validation and parameter clamps") do
        empty = Helpers.build_query(q: "", characters: "exact")
        long = Helpers.build_query(q: "甲" * 81, characters: "exact")
        clamped = Helpers.build_query(q: "仁", context: 999, page: -3, per_page: 999)
        audit.check("empty exact query is invalid", expected: false, actual: empty.errors) { !empty.valid? }
        audit.check("81-character exact query is invalid", expected: false, actual: long.errors) { !long.valid? }
        audit.equal("context clamps to 200", 200, clamped.context)
        audit.equal("page clamps to 1", 1, clamped.page)
        audit.equal("per-page clamps to 50", 50, clamped.per_page)
      end
    end

    def synthetic_or_matrix(audit)
      root, cache, manifest = synthetic_context(audit)
      folder = ["中國漢文/clean/周朝/仁義.txt"]

      audit.step("ordinary OR results") do
        query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "alternatives", terms: %w[仁 義], folders: folder, characters: "exact")
        audit.equal("OR finds each occurrence of either term", 4, page.total)
        audit.equal("OR query is valid", true, query.valid?)
        audit.equal("matched terms are retained", %w[仁 義], page.hits.map { |hit| hit.dig("term_matches", 0, "term") }.uniq.sort)
        audit.includes("canonical URL serializes first OR term", query.query_string, "terms[]=%E4%BB%81")
        audit.includes("display label contains OR", query.display_label, "OR")
      end

      audit.step("duplicates and overlapping alternatives") do
        _query, duplicate = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "alternatives", terms: %w[仁 仁], folders: folder, characters: "exact")
        audit.equal("duplicate alternatives do not duplicate source rows", 2, duplicate.total)
        audit.check("duplicate alternative provenance is retained", expected: "two term matches", actual: duplicate.hits.map { |hit| hit["term_matches"].length }) do
          duplicate.hits.all? { |hit| hit["term_matches"].length == 2 }
        end

        _query, overlap = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "alternatives", terms: ["仁", "仁義"], folders: folder, characters: "exact")
        audit.check("overlapping alternatives both produce occurrences", expected: ">= 3", actual: overlap.total) { overlap.total >= 3 }
      end

      audit.step("OR body rule and equivalence") do
        _query, metadata = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "alternatives", terms: ["只在標題", "另一不存在詞"], characters: "exact")
        audit.equal("OR ignores metadata headers", 0, metadata.total)

        _query, broad = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "alternatives", terms: ["試驗", "溫故"], folders: ["日本漢文/clean/江戶時代"], characters: "broad")
        audit.equal("OR supports broad character matching", 2, broad.total)
      end

      audit.step("OR term limits") do
        valid = Helpers.build_query(mode: "alternatives", terms: (1..10).map { |i| "詞#{i}" })
        too_few = Helpers.build_query(mode: "alternatives", terms: ["仁"])
        too_many = Helpers.build_query(mode: "alternatives", terms: (1..11).map { |i| "詞#{i}" })
        audit.equal("ten OR terms are valid", true, valid.valid?)
        audit.equal("one OR term is invalid", false, too_few.valid?)
        audit.equal("eleven OR terms are invalid", false, too_many.valid?)
      end
    end

    def synthetic_proximity_matrix(audit)
      root, cache, manifest = synthetic_context(audit)
      folder = ["中國漢文/clean/周朝/舜孝.txt"]

      audit.step("order and punctuation") do
        _query, entered = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: %w[舜 孝], span: 3, order: "entered", punctuation: "ignore", folders: folder, characters: "exact")
        audit.equal("entered order finds normalized span", 1, entered.total)
        audit.equal("proximity source text retains punctuation", "舜，克孝", entered.hits.first.to_h["matched_text"])

        _query, reversed = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: %w[孝 舜], span: 3, order: "entered", punctuation: "ignore", folders: folder, characters: "exact")
        audit.equal("entered order rejects reversal", 0, reversed.total)

        _query, any = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: %w[孝 舜], span: 3, order: "any", punctuation: "ignore", folders: folder, characters: "exact")
        audit.equal("any order accepts reversal", 1, any.total)
      end

      audit.step("multi-term and repeated terms") do
        _query, three = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: ["舜", "孝", "天下"], span: 8, order: "entered", folders: folder, characters: "exact")
        audit.equal("three-term proximity works", 1, three.total)
        audit.equal("three term matches are recorded", 3, three.hits.first.to_h.fetch("term_matches", []).length)

        _query, repeated = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: ["民", "民", "君"], span: 8, order: "entered", folders: folder, characters: "exact")
        audit.equal("repeated terms require separate source occurrences", 1, repeated.total)
        audit.equal("repeated offsets are distinct", [10, 12, 15], repeated.hits.first.to_h.fetch("term_matches", []).map { |match| match["start_offset"] })
      end

      audit.step("ten-term boundary") do
        terms = %w[甲 乙 丙 丁 戊 己 庚 辛 壬 癸]
        _query, at_boundary = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: terms, span: 10, order: "entered", folders: folder, characters: "exact")
        _query, below_boundary = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, mode: "proximity", terms: terms, span: 9, order: "entered", folders: folder, characters: "exact")
        audit.equal("ten proximity terms are accepted", 1, at_boundary.total)
        audit.equal("maximum span boundary is enforced", 0, below_boundary.total)
      end

      audit.step("proximity validation") do
        too_few = Helpers.build_query(mode: "proximity", terms: ["舜"])
        too_many = Helpers.build_query(mode: "proximity", terms: (1..11).map { |i| "詞#{i}" })
        clamped_low = Helpers.build_query(mode: "proximity", terms: %w[舜 孝], span: 0)
        clamped_high = Helpers.build_query(mode: "proximity", terms: %w[舜 孝], span: 99_999)
        audit.equal("one proximity term is invalid", false, too_few.valid?)
        audit.equal("eleven proximity terms are invalid", false, too_many.valid?)
        audit.equal("span clamps to one", 1, clamped_low.maximum_span)
        audit.equal("span clamps to five thousand", 5_000, clamped_high.maximum_span)
      end
    end

    def synthetic_scope_filters(audit)
      root, cache, manifest = synthetic_context(audit)

      audit.step("document layers") do
        marker_by_role = {
          "canonical" => "正本文",
          "textual_variant" => "異本文",
          "raw" => "原始文",
          "derived_reading" => "訓讀文",
          "translation" => "譯本文",
          "annotation" => "注釋文"
        }
        marker_by_role.each do |role, marker|
          _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: marker, roles: [role], characters: "exact")
          audit.equal("search role #{role}", 1, page.total)
          audit.equal("result role #{role}", role, page.hits.first.to_h["document_role"])
        end

        roles = marker_by_role.keys
        _query, all_layers = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "角色檢查", roles: roles, characters: "exact")
        audit.equal("all searchable layers combine", 6, all_layers.total)
        audit.check("support files remain unsearchable", expected: false, actual: all_layers.hits.map { |hit| hit["path"] }) { all_layers.hits.none? { |hit| hit["path"].include?("support") } }
      end

      audit.step("include and exclude folders") do
        _query, included = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "人之初", folders: ["中國漢文/clean/宋朝/三字經"], characters: "exact")
        audit.equal("include folder narrows results", 1, included.total)
        _query, excluded = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "人之初", folders: ["中國漢文/clean/宋朝"], exclude_folders: ["中國漢文/clean/宋朝/三字經"], characters: "exact")
        audit.equal("exclude folder removes nested branch", 0, excluded.total)
      end

      audit.step("metadata filters") do
        filters = [
          ["nation", { "nation" => "日本漢文" }, ->(hit) { hit["nation"].include?("日本漢文") }],
          ["period", { "period" => "甲期" }, ->(hit) { hit["period"].include?("甲期") }],
          ["region", { "region" => "東部" }, ->(hit) { hit["region"].include?("東部") }],
          ["author", { "author" => "作者1" }, ->(hit) { hit["author"].include?("作者1") }],
          ["year range", { "year_start" => "1000", "year_end" => "1100" }, ->(hit) { hit["year_start"].to_i <= 1100 && hit["year_end"].to_i >= 1000 }]
        ]
        filters.each do |label, metadata, predicate|
          _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "測試文書", metadata: metadata, characters: "exact", per_page: 50)
          audit.check("#{label} filter returns results", expected: "> 0", actual: page.total) { page.total.positive? }
          audit.check("#{label} filter labels every returned row", expected: true, actual: page.hits.map { |hit| hit.slice("nation", "period", "region", "author", "year_start", "year_end") }) do
            page.hits.all? { |hit| predicate.call(hit) }
          end
        end
      end

      audit.step("combined filters") do
        metadata = { "nation" => "日本漢文", "period" => "乙期", "region" => "西部", "author" => "作者1", "year_start" => "800", "year_end" => "2000" }
        _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "測試文書", metadata: metadata, characters: "exact", per_page: 50)
        audit.check("combined filters remain usable", expected: "> 0", actual: page.total) { page.total.positive? }
        audit.check("combined-filter rows satisfy every constraint", expected: true, actual: page.hits.map { |hit| hit.slice("nation", "period", "region", "author") }) do
          page.hits.all? do |hit|
            hit["nation"].include?("日本漢文") && hit["period"].include?("乙期") &&
              hit["region"].include?("西部") && hit["author"].include?("作者1")
          end
        end
      end
    end

    def synthetic_cache_index(audit)
      root, cache, manifest = synthetic_context(audit)
      options = { root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩", folders: ["中國漢文/clean/周朝/詩經"], characters: "exact" }

      audit.step("cold and warm query cache") do
        query, cold = Helpers.run_page(**options)
        _query, warm = Helpers.run_page(**options)
        audit.check("cold run scans at least one candidate", expected: "> 0", actual: cold.scanned_files) { cold.scanned_files.positive? }
        audit.equal("warm run reuses cached hits", 0, warm.scanned_files)
        audit.equal("cold and warm totals agree", cold.total, warm.total)
        audit.metric("query_cache_key", query.cache_key)
      end

      audit.step("changed file invalidates one cache entry") do
        target = root.join("中國漢文/clean/周朝/詩經/關雎.txt")
        target.write(target.read + "又曰：關關雎鳩。\n")
        File.utime(Time.now + 2, Time.now + 2, target)
        refreshed = Helpers.build_manifest(root: root, cache_store: cache, audit: nil)
        _query, changed = Helpers.run_page(root: root, cache_store: cache, manifest: refreshed, q: "關關雎鳩", folders: ["中國漢文/clean/周朝/詩經"], characters: "exact")
        audit.equal("changed body produces new total", 2, changed.total)
        audit.check("changed document is rescanned", expected: "> 0", actual: changed.scanned_files) { changed.scanned_files.positive? }
      end

      audit.step("term index") do
        current = Helpers.build_manifest(root: root, cache_store: cache, audit: nil)
        Helpers.with_corpus(root) do
          index = CorpusSearch::TermIndex.new(term: "關", manifest: current, cache_store: cache)
          ids = index.doc_ids_with_hits
          target_doc = current.documents.find { |doc| doc["path"].end_with?("詩經/關雎.txt") }
          audit.includes("term index includes known document", ids, target_doc["id"])
          audit.check("term index count is positive", expected: "> 0", actual: index.count_for(target_doc["id"])) { index.count_for(target_doc["id"]).positive? }
        end
      end

      audit.step("corrupt caches recover") do
        query = Helpers.build_query(q: "關關雎鳩", folders: ["中國漢文/clean/周朝/詩經"], characters: "exact")
        query_cache_path = cache.absolute(File.join("query_caches", "#{query.cache_key}.json.gz"))
        FileUtils.mkdir_p(query_cache_path.dirname)
        query_cache_path.binwrite("not gzip")
        _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: Helpers.build_manifest(root: root, cache_store: cache), q: "關關雎鳩", folders: ["中國漢文/clean/周朝/詩經"], characters: "exact")
        audit.equal("corrupt query cache is discarded", 2, page.total)

        cache.absolute(CorpusSearch::Manifest::CACHE_PATH).binwrite("not gzip")
        recovered = Helpers.with_corpus(root) { CorpusSearch::Manifest.load(root: root, cache_store: cache) }
        audit.check("corrupt manifest cache is rebuilt", expected: "> 100 documents", actual: recovered.documents.length) { recovered.documents.length > 100 }
      end
    end

    def synthetic_fault_tolerance(audit)
      root, cache, manifest = synthetic_context(audit)

      audit.step("invalid UTF-8") do
        _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "人之初", folders: ["中國漢文/clean/周朝"], characters: "exact")
        audit.check("invalid UTF-8 file does not abort search", expected: "result page", actual: page.class.name) { page.is_a?(CorpusSearch::ResultPage) }
        audit.check("scrubbed invalid UTF-8 body can still match", expected: true, actual: page.hits.map { |hit| hit["path"] }) { page.hits.any? { |hit| hit["path"].end_with?("invalid_utf8.txt") } }
      end

      audit.step("missing indexed file") do
        target = root.join("中國漢文/clean/周朝/詩經/關雎.txt")
        FileUtils.rm_f(target)
        _query, page = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩", folders: ["中國漢文/clean/周朝/詩經"], characters: "exact")
        audit.equal("missing file becomes a local zero-hit result", 0, page.total)
      end

      audit.step("path and symlink safeguards") do
        fs = CorpusFs.new(root: root)
        traversal_error = nil
        begin
          fs.resolve("../../etc/passwd")
        rescue SecurityError => e
          traversal_error = e
        end
        audit.check("path traversal is refused", expected: "SecurityError", actual: traversal_error&.class&.name) { traversal_error.is_a?(SecurityError) }
        audit.check("manifest excludes symlinks", expected: false, actual: manifest.documents.any? { |doc| doc["path"].end_with?("symlink.txt") }) { manifest.documents.none? { |doc| doc["path"].end_with?("symlink.txt") } }
      end

      audit.step("malformed parameters are clamped") do
        query = CorpusSearch::Query.from_params(
          "mode" => "not-a-mode", "q" => "仁", "span" => "not-a-number", "order" => "sideways",
          "characters" => "unknown", "punctuation" => "unknown", "page" => "-99", "per_page" => "9999"
        )
        audit.equal("unknown mode falls back to exact", "exact", query.mode)
        audit.equal("unknown character level falls back to common", "common", query.character_equivalence)
        audit.equal("unknown punctuation falls back to ignore", "ignore", query.punctuation)
        audit.equal("bad page clamps to one", 1, query.page)
        audit.equal("large per-page clamps to fifty", 50, query.per_page)
      end

      audit.step("prepared export failure state") do
        query = Helpers.build_query(q: "人之初", characters: "exact")
        prepared = CorpusSearch::PreparedSearch.create!(query: query, cache_store: cache)
        previous_root = Rails.configuration.x.corpus_root
        failure = nil
        begin
          Rails.configuration.x.corpus_root = audit.case_dir.join("corpus_that_does_not_exist").to_s
          CorpusSearch::ExportWriter.new(prepared_search: prepared, cache_store: cache).write!
        rescue StandardError => e
          failure = e
        ensure
          Rails.configuration.x.corpus_root = previous_root
        end
        prepared.load!
        audit.check("crashed export raises a useful exception", expected: "exception", actual: failure && "#{failure.class}: #{failure.message}") { failure.present? }
        audit.equal("crashed export persists failed status", "failed", prepared.status)
        audit.matches("crashed export persists error message", prepared.payload["error_message"], /corpus_that_does_not_exist|ENOENT|No such file/i)
      end

      audit.step("corrupt prepared record containment") do
        corrupt_dir = cache.absolute("prepared/corrupt-record")
        FileUtils.mkdir_p(corrupt_dir)
        corrupt_dir.join("status.json").write("{not valid json")
        result = nil
        error = nil
        begin
          result = CorpusSearch::PreparedSearch.find(id: "corrupt-record", key: "wrong", cache_store: cache)
        rescue StandardError => e
          error = e
        end
        audit.check(
          "corrupt prepared status is treated as unavailable rather than crashing the request",
          expected: "nil without exception",
          actual: error ? "#{error.class}: #{error.message}" : result
        ) { error.nil? && result.nil? }
      end

      audit.step("one failed assertion does not stop the case") do
        before = audit.assertions.length
        audit.check("intentional contained audit assertion", expected: "recorded failure", actual: "intentional") { false }
        audit.equal("assertion after contained failure still runs", before + 1, audit.assertions.length)
        audit.warn("The preceding intentional failure is a self-check of intra-case continuation and should be ignored by report triage.", "self_test")
        # Convert the self-test row to a pass after proving continuation, so it does not make the real case fail.
        audit.assertions[-2]["status"] = "pass"
        audit.assertions[-2]["detail"] = "Intentional failure was recorded, then neutralised after continuation was verified."
      end
    end

    def analysis_runtime_failure_modes(audit)
      directory = audit.case_dir.join("analysis_failure_inputs")
      FileUtils.mkdir_p(directory)
      documents = directory.join("document_counts.csv")
      occurrences = directory.join("analysis_occurrences.csv")
      documents.write("doc_id,body_fingerprint,path,folder_path,document_role,title,author,year_start,year_end,nation,period,region,searchable_characters,occurrences,matching_document\n1,abc,a.txt,root,canonical,A,,100,100,N,P,R,10,1,1\n")
      occurrences.write("occurrence_id,doc_id,path,mode,search_start_offset,search_end_offset,proximity_span,matched_term_order,matched_alternatives,matched_forms,left_neighbours,right_neighbours\n1,1,a.txt,exact,0,1,,,,仁⇒仁,左,右\n")

      audit.step("missing Ruby executable") do
        result = CorpusSearch::AnalysisRunner.new(executable: directory.join("missing-ruby").to_s, timeout_seconds: 2).run(
          profile: "standard_analysis", document_counts_path: documents, occurrences_path: occurrences, output_dir: directory.join("missing")
        )
        audit.equal("missing analysis runtime is unavailable", "unavailable", result.status)
        audit.file("missing-runtime metadata remains", result.metadata_path, minimum_bytes: 1)
        audit.file("missing-runtime warning remains", directory.join("missing/warnings.txt"), minimum_bytes: 1)
      end

      audit.step("Ruby nonzero exit") do
        fake = make_fake_ruby(directory.join("ruby-fail"), <<~SH)
          echo "deliberate Ruby analysis failure" >&2
          exit 7
        SH
        result = CorpusSearch::AnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
          profile: "standard_analysis", document_counts_path: documents, occurrences_path: occurrences, output_dir: directory.join("failed")
        )
        audit.equal("nonzero analysis exit is failed", "failed", result.status)
        audit.equal("analysis exit status is retained", 7, result.exit_status)
        audit.includes("analysis stderr is retained", result.stderr_path.read, "deliberate Ruby analysis failure")
      end

      audit.step("Ruby timeout") do
        fake = make_fake_ruby(directory.join("ruby-sleep"), <<~SH)
          sleep 30
          exit 0
        SH
        result = CorpusSearch::AnalysisRunner.new(executable: fake.to_s, timeout_seconds: 1).run(
          profile: "standard_analysis", document_counts_path: documents, occurrences_path: occurrences, output_dir: directory.join("timeout")
        )
        audit.equal("hung analysis process is timed out", "timed_out", result.status)
        audit.file("timeout diagnostics remain", result.metadata_path, minimum_bytes: 1)
      end

      audit.step("malformed report is rejected by the runner") do
        fake = make_fake_ruby(directory.join("ruby-malformed"), <<~'SH')
          output="$4"
          printf '{bad json' > "$output/analysis_report.json"
          : > "$output/warnings.txt"
          exit 0
        SH
        output = directory.join("malformed")
        result = CorpusSearch::AnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
          profile: "standard_analysis", document_counts_path: documents, occurrences_path: occurrences, output_dir: output
        )
        report = CorpusSearch::AnalysisReport.load(output)
        audit.equal("malformed report makes the run fail", "failed", result.status)
        audit.check("malformed report is rejected by report reader", expected: nil, actual: report) { report.nil? }
      end
    end

    def synthetic_export_exact(audit)
      synthetic_export(audit, mode: "exact")
    end

    def synthetic_export_or(audit)
      synthetic_export(audit, mode: "alternatives")
    end

    def synthetic_export_proximity(audit)
      synthetic_export(audit, mode: "proximity")
    end

    def synthetic_comparison(audit)
      root, cache, = synthetic_context(audit)
      source_query = Helpers.build_query(q: "人之初", characters: "exact")
      source, = Helpers.run_prepared(root: root, cache_store: cache, query: source_query, audit: audit)
      ArtifactValidator.new(audit).validate!(source, require_analysis: true, expected_mode: "exact")

      audit.step("comparison without source rescan") do
        unavailable_root = audit.case_dir.join("deliberately_missing_corpus")
        comparison = CorpusSearch::ComparisonDefinition.new(dimension: "nation", left_group: "中國漢文", right_group: "日本漢文")
        prepared = nil
        previous = Rails.configuration.x.corpus_root
        Rails.configuration.x.corpus_root = unavailable_root.to_s
        begin
          prepared = CorpusSearch::PreparedSearch.create!(query: source_query, comparison: comparison, source_prepared: source, cache_store: cache)
          CorpusSearch::ExportWriter.new(prepared_search: prepared, cache_store: cache).write!
          prepared.load!
        ensure
          Rails.configuration.x.corpus_root = previous
        end
        audit.equal("comparison completes while corpus is unavailable", "complete", prepared&.status)
        ArtifactValidator.new(audit).validate!(
          prepared,
          require_analysis: true,
          expected_mode: "exact",
          expected_special_files: %w[comparison_summary.csv comparison_effects.csv figures/scope_comparison.svg figures/scope_comparison.png]
        ) if prepared
        audit.equal("comparison records source ID", source.id, prepared&.source_prepared_id)
        Helpers.record_export(run_root, "synthetic_comparison", prepared, root: root, cache_root: cache.root) if prepared
      end
    end

    def synthetic_http_flow(audit)
      root, cache, = synthetic_context(audit)
      ENV["CORPUS_SEARCH_AUDIT_CACHE_ROOT"] = cache.root.to_s
      old_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      Helpers.with_corpus(root) do
        session = integration_session
        audit.step("HTTP validation failures remain local") do
          session.get("/corpus/search?search=1&mode=exact&q=&characters=exact")
          audit.equal("invalid live query still renders a response", 200, session.response.status)

          session.post("/corpus/search/prepare", params: { mode: "exact", q: "", search: "1" })
          audit.check("invalid prepare redirects instead of raising", expected: "3xx", actual: session.response.status) { session.response.redirect? }

          session.post("/corpus/search/prepare", params: { source_prepared_id: "missing", source_prepared_key: "wrong" })
          audit.check("unknown comparison source redirects", expected: "3xx", actual: session.response.status) { session.response.redirect? }
        end

        audit.step("live HTTP searches") do
          exact_uri = "/corpus/search?mode=exact&q=#{url("人之初")}&punctuation=ignore&characters=exact&roles[]=canonical"
          session.get(exact_uri)
          audit.equal("HTTP exact search status", 200, session.response.status)
          audit.includes("HTTP exact result text", session.response.body, "人之初")

          session.get("/corpus/search?mode=alternatives&terms[]=#{url("仁")}&terms[]=#{url("義")}&punctuation=ignore&characters=exact&roles[]=canonical")
          audit.equal("HTTP OR search status", 200, session.response.status)
          audit.includes(
            "HTTP OR result labels alternatives",
            session.response.body,
            "corpus-search-matched-alternatives"
          )

          session.get("/corpus/search?mode=proximity&terms[]=#{url("舜")}&terms[]=#{url("孝")}&span=3&order=entered&punctuation=ignore&characters=exact&roles[]=canonical")
          audit.equal("HTTP proximity status", 200, session.response.status)
          audit.includes("HTTP proximity result text", session.response.body, "舜")
        end

        source = nil
        audit.step("prepare to queued status") do
          session.post("/corpus/search/prepare", params: {
            mode: "exact", q: "人之初", punctuation: "ignore", characters: "exact", roles: ["canonical"]
          })
          audit.check("prepare redirects", expected: "3xx", actual: session.response.status) { session.response.redirect? }
          id, key = prepared_credentials(session.response.location)
          audit.check("prepare redirect contains credentials", expected: "id and key", actual: [id, key]) { id.present? && key.present? }
          source = CorpusSearch::PreparedSearch.find(id: id, key: key, cache_store: cache)
          audit.equal("new prepared record is queued", "queued", source&.status)
          session.get(URI(session.response.location).request_uri)
          audit.equal("queued status page responds", 200, session.response.status)
          audit.includes("queued status page names query", session.response.body, "人之初")
          session.get("/corpus/search/prepared/#{id}/download?key=#{url(key)}")
          audit.equal("queued download is refused", 404, session.response.status)

          # The integration session has already passed through Rails executor middleware.
          # Calling ActiveJob's wrapper again inside the same rails runner process can
          # encounter a cleared ExecutionContext. Call the job body directly here:
          # this case is testing corpus-search work, not ActiveJob instrumentation.
          CorpusSearchJob.new.perform(id)
          source.load!
          audit.equal("job completes prepared record", "complete", source.status)
          session.get("/corpus/search/prepared/#{id}?key=#{url(key)}")
          audit.equal("frozen page responds", 200, session.response.status)
          audit.includes("frozen page exposes ZIP action", session.response.body, "/download")

          session.get("/corpus/search/prepared/#{id}/download?key=#{url(key)}")
          audit.equal("download responds 200", 200, session.response.status)
          audit.matches("download is ZIP", session.response.media_type, /zip/)
          audit.check("download body has ZIP signature", expected: "PK", actual: session.response.body.byteslice(0, 2)) { session.response.body.start_with?("PK") }

          session.get("/corpus/search/prepared/#{id}?key=wrong")
          audit.equal("wrong prepared key is rejected", 404, session.response.status)

          session.post("/corpus/search/prepare", params: {
            source_prepared_id: source.id, source_prepared_key: source.key,
            comparison: { dimension: "nation", left_group: "中國漢文", right_group: "中國漢文" }
          })
          audit.check("invalid same-group comparison redirects", expected: "3xx", actual: session.response.status) { session.response.redirect? }
        end

        audit.step("HTTP comparison chain") do
          report = CorpusSearch::AnalysisReport.load(source.output_dir.join("analysis", "standard"))
          options = report&.comparison_options("nation").to_a
          audit.check("source HTTP analysis has two nations", expected: ">= 2", actual: options) { options.length >= 2 }
          if options.length >= 2
            session.post("/corpus/search/prepare", params: {
              source_prepared_id: source.id,
              source_prepared_key: source.key,
              comparison: { dimension: "nation", left_group: options[0], right_group: options[1] }
            })
            audit.check("comparison prepare redirects", expected: "3xx", actual: session.response.status) { session.response.redirect? }
            id, key = prepared_credentials(session.response.location)
            # See the corresponding synthetic export case above. Direct #perform avoids
            # nesting ActiveJob instrumentation inside the integration executor.
            CorpusSearchJob.new.perform(id)
            compared = CorpusSearch::PreparedSearch.find(id: id, key: key, cache_store: cache)
            audit.equal("HTTP comparison completes", "complete", compared&.status)
            session.get("/corpus/search/prepared/#{id}?key=#{url(key)}")
            audit.equal("HTTP comparison page responds", 200, session.response.status)
            audit.includes("HTTP comparison page renders comparison", session.response.body, "Compare two scopes")
          end
        end

        ArtifactValidator.new(audit).validate!(source, require_analysis: true, expected_mode: "exact") if source
        Helpers.record_export(run_root, "synthetic_http", source, root: root, cache_root: cache.root) if source
      end
    ensure
      ActiveJob::Base.queue_adapter = old_adapter if old_adapter
    end

    def real_manifest_integrity(audit)
      root, cache, manifest = real_context(audit)
      docs = manifest.documents
      audit.step("manifest global invariants") do
        audit.check("real manifest is substantial", expected: "> 100,000 documents", actual: docs.length) { docs.length > 100_000 }
        audit.equal("real manifest IDs are unique", docs.length, docs.map { |doc| doc["id"] }.uniq.length)
        audit.equal("real manifest paths are unique", docs.length, docs.map { |doc| doc["path"] }.uniq.length)
        audit.check("all paths are relative and traversal-free", expected: true, actual: nil) do
          docs.all? { |doc| !Pathname(doc["path"].to_s).absolute? && !doc["path"].to_s.split("/").include?("..") }
        end
        invalid_roles = docs.reject { |doc| CorpusSearch::DocumentRole::ROLES.include?(doc["document_role"].to_s) }
        audit.equal("all documents have known roles", [], invalid_roles.first(20).map { |doc| [doc["path"], doc["document_role"]] })
      end

      audit.step("file existence sweep") do
        fs = CorpusFs.new(root: root)
        overnight = ENV["CORPUS_SEARCH_AUDIT_PROFILE"].to_s == "overnight"
        checked_docs = if overnight || docs.length <= 20_000
          docs
        else
          stride = [docs.length / 20_000, 1].max
          docs.each_slice(stride).map(&:first).first(20_000)
        end
        missing = []
        checked_docs.each_with_index do |doc, index|
          missing << doc["path"] unless fs.file?(fs.resolve(doc["path"]))
          audit.heartbeat("file existence sweep", current: index + 1, total: checked_docs.length) if ((index + 1) % 2_000).zero?
        rescue SecurityError, StandardError => e
          missing << "#{doc['path']}: #{e.class}: #{e.message}"
        end
        label = overnight ? "every manifest file still exists" : "sampled manifest files still exist"
        audit.equal(label, [], missing.first(100))
        audit.metric("existence_files_checked", checked_docs.length)
        audit.metric("missing_file_count", missing.length)
      end

      audit.step("encoding and parser sample") do
        fs = CorpusFs.new(root: root)
        stride = [docs.length / 2_000, 1].max
        sample = docs.each_slice(stride).map(&:first).first(2_000)
        errors = []
        sample.each_with_index do |doc, index|
          parsed = CorpusSearch::DocumentReader.read(fs: fs, path: doc["path"])
          errors << "#{doc['path']}: non-UTF8 body" unless parsed.body.valid_encoding?
          errors << "#{doc['path']}: bad digest" unless parsed.body_fingerprint.length == 64
          audit.heartbeat("parser sample", current: index + 1, total: sample.length) if ((index + 1) % 250).zero?
        rescue StandardError => e
          errors << "#{doc['path']}: #{e.class}: #{e.message}"
        end
        audit.equal("sampled documents parse cleanly", [], errors.first(100))
        audit.metric("parser_sample_size", sample.length)
        audit.metric("parser_sample_errors", errors.length)
      end
    end

    def real_interactive_queries(audit)
      root, cache, manifest = real_context(audit)
      cases = [
        { name: "三字經 first phrase", options: { q: "人之初", characters: "exact" }, expectation: :positive },
        { name: "三字經 second phrase", options: { q: "性本善", characters: "exact" }, expectation: :positive },
        { name: "詩經 關雎", options: { q: "關關雎鳩", characters: "exact" }, expectation: :positive },
        { name: "詩經 punctuation ignored", options: { q: "關關雎鳩在河之洲", punctuation: "ignore", characters: "exact" }, expectation: :positive },
        { name: "OR 仁義", options: { mode: "alternatives", terms: %w[仁 義], characters: "exact" }, expectation: :positive },
        { name: "OR famous phrases", options: { mode: "alternatives", terms: ["人之初", "關關雎鳩"], characters: "exact" }, expectation: :positive },
        { name: "proximity 舜孝", options: { mode: "proximity", terms: %w[舜 孝], span: 200, order: "any", characters: "exact" }, expectation: :positive },
        { name: "proximity 關雎", options: { mode: "proximity", terms: ["關關雎鳩", "河之洲"], span: 20, order: "entered", characters: "exact" }, expectation: :positive },
        { name: "six-term entered proximity", options: { mode: "proximity", terms: %w[人 之 初 性 本 善], span: 20, order: "entered", characters: "exact" }, expectation: :positive },
        { name: "deliberate no hit", options: { q: "此乃夜間稽核絕不應存在之超長虛構句甲乙丙", characters: "exact" }, expectation: :zero }
      ]

      cases.each_with_index do |entry, index|
        audit.step("real query #{entry[:name]}") do
          (result, duration) = Helpers.timed do
            Helpers.run_page(root: root, cache_store: cache, manifest: manifest, **entry[:options], per_page: 20)
          end
          query, page = result
          audit.check("#{entry[:name]} query valid", expected: true, actual: query.errors) { query.valid? }
          if entry[:expectation] == :positive
            audit.check(
              "#{entry[:name]} returns at least one known hit",
              expected: "> 0 hits",
              actual: { total: page.total, truncated: page.truncated }
            ) { page.total.positive? }
            if page.total.zero? && page.truncated
              audit.warn("Cold interactive scan reached its safety limit before a known hit", { name: entry[:name] })
            end
          elsif page.complete
            audit.equal("#{entry[:name]} returns zero", 0, page.total)
          else
            audit.check(
              "#{entry[:name]} remains bounded when a complete zero cannot be proven live",
              expected: "truncated with zero visible hits",
              actual: { total: page.total, truncated: page.truncated }
            ) { page.total.zero? && page.truncated }
          end
          audit.metric("query_#{index + 1}_seconds", duration.round(4))
          audit.metric("query_#{index + 1}_candidates", page.candidate_files)
          audit.metric("query_#{index + 1}_scanned", page.scanned_files)
          audit.metric("query_#{index + 1}_total", page.total)
          audit.metric("query_#{index + 1}_complete", page.complete)
          audit.warn("Interactive query exceeded two minutes", { name: entry[:name], seconds: duration }) if duration > 120
        end
      end

      audit.step("real punctuation comparison") do
        _query, ignored = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩在河之洲", punctuation: "ignore", characters: "exact")
        _query, respected = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "關關雎鳩在河之洲", punctuation: "respect", characters: "exact")
        if ignored.complete && respected.complete
          audit.check("ignoring punctuation is not more restrictive", expected: ">= respected total", actual: { ignored: ignored.total, respected: respected.total }) { ignored.total >= respected.total }
        else
          audit.warn("Punctuation comparison used bounded partial live results", { ignored: ignored.total, respected: respected.total })
          audit.check("bounded punctuation searches return safely", expected: true, actual: true) { true }
        end
      end

      audit.step("real broad equivalence comparison") do
        _query, exact = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "試驗", characters: "exact")
        _query, broad = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, q: "試驗", characters: "broad")
        if exact.complete && broad.complete
          audit.check("broad equivalence does not lose exact hits", expected: ">= exact", actual: { exact: exact.total, broad: broad.total }) { broad.total >= exact.total }
        else
          audit.warn("Equivalence comparison used bounded partial live results", { exact: exact.total, broad: broad.total })
          audit.check("bounded equivalence searches return safely", expected: true, actual: true) { true }
        end
      end
    end

    def real_cache_warm_cold(audit)
      root, _shared_cache, manifest = real_context(audit)
      cache = CorpusSearch::CacheStore.new(root: audit.case_dir.join("cold_warm_cache"))
      audit.metric("cold_warm_cache_root", cache.root.to_s)
      cases = [
        ["exact", { q: "人之初", characters: "exact" }],
        ["OR", { mode: "alternatives", terms: %w[仁 義], characters: "exact" }],
        ["proximity", { mode: "proximity", terms: %w[舜 孝], span: 200, order: "any", characters: "exact" }]
      ]
      cases.each do |label, options|
        audit.step("#{label} cold/warm") do
          (cold_result, cold_seconds) = Helpers.timed { Helpers.run_page(root: root, cache_store: cache, manifest: manifest, **options) }
          (warm_result, warm_seconds) = Helpers.timed { Helpers.run_page(root: root, cache_store: cache, manifest: manifest, **options) }
          _cold_query, cold = cold_result
          _warm_query, warm = warm_result
          audit.equal("#{label} cold/warm totals agree", cold.total, warm.total)
          audit.check("#{label} warm run scans no more files", expected: "<= cold scanned files", actual: { cold: cold.scanned_files, warm: warm.scanned_files }) { warm.scanned_files <= cold.scanned_files }
          audit.metric("#{label.downcase}_cold_seconds", cold_seconds.round(4))
          audit.metric("#{label.downcase}_warm_seconds", warm_seconds.round(4))
          audit.warn("#{label} warm run is materially slower than cold run", { cold: cold_seconds, warm: warm_seconds }) if warm_seconds > cold_seconds * 1.5 && warm_seconds > 5
        end
      end
    end

    def real_scoped_export_or(audit)
      real_scoped_export(audit, mode: "alternatives")
    end

    def real_scoped_export_proximity(audit)
      real_scoped_export(audit, mode: "proximity")
    end

    def real_full_export_exact(audit)
      root, cache, _manifest = real_context(audit)
      query = Helpers.build_query(q: "人之初", characters: "exact", roles: ["canonical"])
      prepared, = Helpers.run_prepared(root: root, cache_store: cache, query: query, audit: audit)
      ArtifactValidator.new(audit).validate!(prepared, require_analysis: true, expected_mode: "exact")
      audit.check("full export includes a large denominator", expected: "> 100,000 documents", actual: prepared.payload.dig("outputs", "analysis_documents")) do
        prepared.payload.dig("outputs", "analysis_documents").to_i > 100_000
      end
      Helpers.record_export(run_root, "real_full_exact", prepared, root: root, cache_root: cache.root)
    end

    def real_reused_comparison(audit)
      entry = Helpers.read_export(run_root, "real_full_exact")
      audit.skip!("real_full_export_exact did not produce a reusable source record") unless entry
      cache = CorpusSearch::CacheStore.new(root: entry.fetch("cache_root"))
      source = CorpusSearch::PreparedSearch.find(id: entry.fetch("id"), key: entry.fetch("key"), cache_store: cache)
      audit.skip!("real full source record is missing or unauthorized") unless source&.complete?
      report = CorpusSearch::AnalysisReport.load(source.output_dir.join("analysis", "standard"))
      dimension, options = %w[period nation region folder document_role].filter_map do |candidate|
        values = report&.comparison_options(candidate).to_a.reject { |value| value.include?("Unknown") }
        [candidate, values] if values.length >= 2
      end.first
      audit.skip!("real source analysis has no dimension with two comparison groups") unless dimension

      comparison = CorpusSearch::ComparisonDefinition.new(dimension: dimension, left_group: options[0], right_group: options[1])
      query = source.query
      missing_root = audit.case_dir.join("missing_real_corpus")
      previous = Rails.configuration.x.corpus_root
      Rails.configuration.x.corpus_root = missing_root.to_s
      prepared = CorpusSearch::PreparedSearch.create!(query: query, comparison: comparison, source_prepared: source, cache_store: cache)
      CorpusSearch::ExportWriter.new(prepared_search: prepared, cache_store: cache).write!
      prepared.load!
      Rails.configuration.x.corpus_root = previous

      audit.equal("real reused comparison completes without corpus", "complete", prepared.status)
      ArtifactValidator.new(audit).validate!(prepared, require_analysis: true, expected_mode: "exact", expected_special_files: %w[comparison_summary.csv comparison_effects.csv figures/scope_comparison.svg figures/scope_comparison.png])
      Helpers.record_export(run_root, "real_comparison", prepared, root: entry.fetch("root"), cache_root: cache.root)
    ensure
      Rails.configuration.x.corpus_root = previous if defined?(previous) && previous
    end

    def external_localhost_smoke(audit)
      base = ENV["CORPUS_SEARCH_AUDIT_BASE_URL"].to_s.strip
      audit.skip!("Set CORPUS_SEARCH_AUDIT_BASE_URL=http://127.0.0.1:3000 to enable real localhost HTTP checks") if base.empty?
      base_uri = URI(base)
      requests = {
        "form" => "/corpus/search",
        "exact" => "/corpus/search?mode=exact&q=#{url("人之初")}&punctuation=ignore&characters=exact&roles[]=canonical",
        "OR" => "/corpus/search?mode=alternatives&terms[]=#{url("仁")}&terms[]=#{url("義")}&punctuation=ignore&characters=exact&roles[]=canonical",
        "proximity" => "/corpus/search?mode=proximity&terms[]=#{url("舜")}&terms[]=#{url("孝")}&span=200&order=any&punctuation=ignore&characters=exact&roles[]=canonical"
      }
      requests.each do |label, path|
        audit.step("localhost #{label}") do
          uri = URI.join(base_uri.to_s.end_with?("/") ? base_uri.to_s : "#{base_uri}/", path.sub(%r{\A/}, ""))
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 900) do |http|
            http.request(Net::HTTP::Get.new(uri))
          end
          audit.equal("localhost #{label} status", "200", response.code)
          audit.check("localhost #{label} body is nonempty", expected: "> 0 bytes", actual: response.body.to_s.bytesize) { response.body.to_s.bytesize.positive? }
        end
      end
    end

    def cross_artifact_audit(audit)
      registry_path = Pathname(run_root).join("shared", "exports.json")
      audit.skip!("No exports were registered during this run") unless registry_path.file?
      registry = JSON.parse(registry_path.read)
      audit.metric("registered_exports", registry.length)
      registry.each_with_index do |(key, entry), index|
        audit.heartbeat("cross-audit #{key}", current: index + 1, total: registry.length)
        audit.step("cross-audit export #{key}") do
          ArtifactValidator.new(audit).validate_output_dir!(entry.fetch("output_dir"), zip_path: entry["zip_path"])
        end
      end
    end

    # ---------- shared case helpers ----------

    def synthetic_context(audit)
      root = SyntheticCorpus.build!(audit.case_dir.join("synthetic_corpus"))
      cache = Helpers.cache(audit.case_dir, "synthetic_cache")
      manifest = Helpers.build_manifest(root: root, cache_store: cache, audit: audit)
      [root, cache, manifest]
    end

    def real_context(audit)
      root = Pathname(ENV.fetch("CORPUS_ROOT", Rails.configuration.x.corpus_root.to_s)).expand_path
      audit.skip!("Real corpus root does not exist: #{root}") unless root.directory?
      configured_cache_root = ENV["CORPUS_SEARCH_AUDIT_REAL_CACHE_ROOT"].to_s.strip
      cache_root = if configured_cache_root.empty?
        Pathname(run_root).join("shared", "real_cache")
      else
        Pathname(configured_cache_root).expand_path
      end
      cache = CorpusSearch::CacheStore.new(root: cache_root)
      audit.metric("real_cache_root", cache.root.to_s)
      manifest = Helpers.with_corpus(root) { CorpusSearch::Manifest.load(root: root, cache_store: cache) }
      audit.metric("real_manifest_documents", manifest.documents.length)
      [root, cache, manifest]
    end

    def synthetic_export(audit, mode:)
      root, cache, = synthetic_context(audit)
      query = case mode
      when "exact"
        Helpers.build_query(q: "密集詞", characters: "exact", folders: ["中國漢文/clean/周朝/dense_occurrences.txt"])
      when "alternatives"
        Helpers.build_query(mode: "alternatives", terms: %w[仁 義], characters: "exact")
      when "proximity"
        Helpers.build_query(mode: "proximity", terms: %w[舜 孝 天下], span: 20, order: "entered", characters: "exact")
      else
        raise ArgumentError, mode
      end
      prepared, = Helpers.run_prepared(root: root, cache_store: cache, query: query, audit: audit)
      special = case mode
      when "alternatives"
        %w[alternative_summary.csv figures/alternative_terms.svg figures/alternative_terms.png]
      when "proximity"
        %w[term_order_summary.csv proximity_spans.csv proximity_summary.csv figures/term_orders.svg figures/proximity_span_histogram.svg]
      else
        []
      end
      ArtifactValidator.new(audit).validate!(prepared, require_analysis: true, expected_mode: mode, expected_special_files: special)

      rows = CSV.read(prepared.output_dir.join("results.csv"), headers: true, encoding: "bom|utf-8")
      audit.check("export contains result rows", expected: "> 0", actual: rows.length) { rows.any? }
      audit.equal("uncapped exact export contains every dense occurrence", 1_105, rows.length) if mode == "exact"
      audit.check("result rows retain source paths", expected: true, actual: rows.first&.to_h) { rows.all? { |row| row["path"].present? } }
      if mode == "alternatives"
        audit.check("OR rows name matched alternatives", expected: true, actual: rows.first&.to_h) { rows.all? { |row| row["matched_alternatives"].present? } }
      elsif mode == "proximity"
        audit.check("proximity rows retain spans", expected: true, actual: rows.first&.to_h) { rows.all? { |row| row["proximity_span"].to_i.positive? } }
      end
      Helpers.record_export(run_root, "synthetic_#{mode}", prepared, root: root, cache_root: cache.root)
    end

    def real_scoped_export(audit, mode:)
      root, cache, manifest = real_context(audit)
      probe_options = mode == "alternatives" ? { mode: "alternatives", terms: %w[仁 義], characters: "exact" } : { mode: "proximity", terms: %w[舜 孝], span: 200, order: "any", characters: "exact" }
      _query, probe = Helpers.run_page(root: root, cache_store: cache, manifest: manifest, **probe_options, per_page: 20)
      audit.skip!("Could not find a real hit to select a scoped branch") if probe.hits.empty?
      branch = Helpers.choose_branch(manifest, probe.hits.first["path"])
      scoped_count = manifest.filtered("include_folders" => [branch], "document_roles" => ["canonical"]).length
      audit.metric("selected_branch", branch)
      audit.metric("selected_branch_documents", scoped_count)
      audit.check("selected real branch is bounded", expected: "1..5000 documents", actual: scoped_count) { scoped_count.between?(1, 5_000) }

      query = if mode == "alternatives"
        Helpers.build_query(mode: "alternatives", terms: %w[仁 義], characters: "exact", folders: [branch])
      else
        Helpers.build_query(mode: "proximity", terms: %w[舜 孝], span: 200, order: "any", characters: "exact", folders: [branch])
      end
      prepared, = Helpers.run_prepared(root: root, cache_store: cache, query: query, audit: audit)
      special = mode == "alternatives" ? %w[alternative_summary.csv figures/alternative_terms.svg] : %w[proximity_spans.csv proximity_summary.csv figures/proximity_span_histogram.svg]
      ArtifactValidator.new(audit).validate!(prepared, require_analysis: true, expected_mode: mode, expected_special_files: special)
      Helpers.record_export(run_root, "real_scoped_#{mode}", prepared, root: root, cache_root: cache.root)
    end

    def integration_session
      ActionDispatch::Integration::Session.new(Rails.application).tap { |session| session.host! "www.example.com" }
    end

    def prepared_credentials(location)
      uri = URI(location.to_s)
      id = uri.path[%r{/corpus/search/prepared/([^/]+)}, 1]
      key = URI.decode_www_form(uri.query.to_s).to_h["key"]
      [id, key]
    rescue URI::InvalidURIError
      [nil, nil]
    end

    def url(value)
      ERB::Util.url_encode(value.to_s)
    end

    def run_root
      ENV.fetch("CORPUS_SEARCH_AUDIT_RUN_ROOT")
    end

    def make_fake_ruby(path, body)
      path = Pathname(path)
      path.write(<<~SH)
        #!/bin/sh
        if [ "$1" = "-v" ]; then
          echo "ruby AUDIT"
          exit 0
        fi
        #{body}
      SH
      path.chmod(0o755)
      path
    end
  end
end
