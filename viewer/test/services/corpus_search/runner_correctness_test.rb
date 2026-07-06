require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchRunnerCorrectnessTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("runner-correctness"))
    @corpus_root = @directory.join("corpus")
    @cache_root = @directory.join("cache")
    @cache_store = CorpusSearch::CacheStore.new(root: @cache_root)

    write("中國漢文/clean/周朝/metadata_only.txt", "# TITLE: 關關雎鳩在河之洲\n\n無匹配正文\n")
    write("中國漢文/clean/周朝/body.txt", "# TITLE: Body\n\n關關雎鳩，在河之洲。\n")
    write("中國漢文/clean/周朝/proximity.txt", "# TITLE: Proximity\n\n舜，克孝，聞於天下。\n")
    write("中國漢文/clean/周朝/repeated.txt", "# TITLE: Repeated\n\n民與民共事君。\n")
    write("中國漢文/clean/周朝/alternatives.txt", "# TITLE: 仁義不入正文搜尋\n\n君子仁而有義。\n")
    write("日本漢文/clean/江戶時代/broad.txt", "# TITLE: Broad\n\n試験之法。\n")
    write("中國漢文/clean/周朝/variants/variant.txt", "關關雎鳩在河之洲\n")
    write("中國漢文/raw/周朝/raw.txt", "關關雎鳩在河之洲\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "a small cold scope scans directly without building a global term index" do
    page = run_query(CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩"))

    assert_equal 1, page.total
    assert_equal default_scoped_document_count, page.candidate_files
    refute @cache_store.exist?(CorpusSearch::TermIndex.cache_path_for("關"))
  end

  test "a small scope scans directly even when a global term index exists" do
    definition = CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩")

    page = with_manifest do |manifest|
      CorpusSearch::TermIndex.refresh_single_character_terms!(
        terms: ["關"],
        manifest: manifest,
        cache_store: @cache_store,
        force: true
      )
      run_query_with_manifest(definition, manifest)
    end

    assert_equal 1, page.total
    assert_equal default_scoped_document_count, page.candidate_files
  end

  test "a stale index does not hide a new hit inside a small scope" do
    definition = CorpusSearch::SearchDefinition.new(query_text: "新增")

    original_manifest = with_manifest do |manifest|
      CorpusSearch::TermIndex.refresh_single_character_terms!(
        terms: ["新"],
        manifest: manifest,
        cache_store: @cache_store,
        force: true
      )
      manifest
    end
    old_fingerprint = CorpusSearch::TermIndex.manifest_fingerprint(original_manifest)

    write("中國漢文/clean/周朝/new_hit.txt", "# TITLE: New\n\n此處新增正文。\n")

    page = with_manifest(force: true) do |manifest|
      refute_equal old_fingerprint, CorpusSearch::TermIndex.manifest_fingerprint(manifest)
      run_query_with_manifest(definition, manifest)
    end

    assert_equal 1, page.total
    assert_equal "中國漢文/clean/周朝/new_hit.txt", page.hits.fetch(0)["path"]
  end

  test "a broad cold scope scans directly without synchronously building an index" do
    previous = ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"]
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = "1"

    page = run_query(CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩"))

    assert_equal 1, page.total
    assert_equal default_scoped_document_count, page.candidate_files
    refute @cache_store.exist?(CorpusSearch::TermIndex.cache_path_for("關"))
  ensure
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = previous
  end

  test "a broad scope reuses a current explicitly warmed index" do
    previous = ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"]
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = "1"
    definition = CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩")

    page = with_manifest do |manifest|
      CorpusSearch::TermIndex.refresh_single_character_terms!(
        terms: ["關"],
        manifest: manifest,
        cache_store: @cache_store,
        force: true
      )
      run_query_with_manifest(definition, manifest)
    end

    assert_equal 1, page.total
    assert_equal 1, page.candidate_files
  ensure
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = previous
  end

  test "punctuation-free exact sequences find punctuated source text at original offsets" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    hit = page.hits.fetch(0)
    assert_equal "中國漢文/clean/周朝/body.txt", hit["path"]
    assert_equal "關關雎鳩，在河之洲", hit["matched_text"]
    assert_equal 0, hit["start_offset"]
    assert_equal 9, hit["end_offset"]
    assert_equal 0, hit["search_start_offset"]
    assert_equal 8, hit["search_end_offset"]
  end

  test "respecting punctuation requires the entered punctuation" do
    no_match = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        punctuation: "respect"
      )
    )
    matching = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩，在河之洲",
        punctuation: "respect"
      )
    )

    assert_equal 0, no_match.total
    assert_equal 1, matching.total
  end

  test "metadata raw files and textual variants remain excluded by default" do
    page = run_query(CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩"))

    assert_equal 1, page.total
    assert_equal "canonical", page.hits.fetch(0)["document_role"]
  end

  test "canonical and textual-variant layers can be searched together" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        document_roles: ["textual_variant", "canonical"]
      )
    )

    assert_equal 2, page.total
    assert_equal %w[canonical textual_variant], page.hits.map { |hit| hit["document_role"] }.sort
  end

  test "textual variants can be selected deliberately" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        document_roles: ["textual_variant"]
      )
    )

    assert_equal 1, page.total
    assert_equal "textual_variant", page.hits.fetch(0)["document_role"]
    assert_equal "中國漢文/clean/周朝", page.hits.fetch(0)["canonical_parent_path"]
  end


  test "broad character matching finds Japanese shinjitai and explains the mapping" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "試驗",
        character_equivalence: "broad"
      )
    )

    assert_equal 1, page.total
    hit = page.hits.fetch(0)
    assert_equal "試験", hit["matched_text"]
    explanation = hit.fetch("equivalence_matches").fetch(0)
    assert_equal "驗", explanation["query_character"]
    assert_equal "験", explanation["source_character"]
    assert_includes explanation["mapping_sources"], "opencc_japanese_shinjitai"
  end

  test "exact character matching does not include script equivalents" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "試驗",
        character_equivalence: "exact"
      )
    )

    assert_equal 0, page.total
  end


  test "alternative search returns occurrences of any entered term" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "alternatives",
        terms: ["仁", "義"],
        punctuation: "ignore"
      )
    )

    assert_equal 2, page.total
    assert_equal ["仁", "義"], page.hits.map { |hit| hit.fetch("term_matches").fetch(0).fetch("term") }
    assert_equal ["仁", "義"], page.hits.map { |hit| hit["matched_text"] }
  end

  test "alternative search does not match metadata headers" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "alternatives",
        terms: ["不入正文搜尋", "不存在"],
        punctuation: "ignore"
      )
    )

    assert_equal 0, page.total
  end

  test "duplicate alternatives do not duplicate the same source occurrence" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "alternatives",
        terms: ["仁", "仁"],
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    assert_equal 2, page.hits.fetch(0).fetch("term_matches").length
  end

  test "proximity span is measured on the punctuation-normalized stream" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["舜", "孝"],
        maximum_span: 3,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    assert_equal "舜，克孝", page.hits.fetch(0)["matched_text"]
  end


  test "proximity supports three or more terms" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["舜", "孝", "天下"],
        maximum_span: 8,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    hit = page.hits.fetch(0)
    assert_equal "舜，克孝，聞於天下", hit["matched_text"]
    assert_equal 3, hit["term_matches"].length
    assert_equal ["舜", "孝", "天下"], hit["term_matches"].map { |match| match["term"] }
  end

  test "repeated proximity terms need separate source occurrences" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["民", "民", "君"],
        maximum_span: 8,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    assert_equal [0, 2, 5], page.hits.fetch(0)["term_matches"].map { |match| match["start_offset"] }
  end

  test "entered proximity order rejects reversed terms" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["孝", "舜"],
        maximum_span: 3,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 0, page.total
  end

  test "bounded interactive searches advance past already cached documents" do
    previous_direct = ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"]
    previous_scan = ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"]
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = "1"
    ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"] = "2"

    with_manifest do |manifest|
      selected = [
        manifest.documents.find { |doc| doc["path"].end_with?("metadata_only.txt") },
        manifest.documents.find { |doc| doc["path"].end_with?("proximity.txt") },
        manifest.documents.find { |doc| doc["path"].end_with?("body.txt") }
      ]
      fake_manifest = Struct.new(:documents) do
        def filtered(_filters) = documents
      end.new(selected)
      definition = CorpusSearch::SearchDefinition.new(query_text: "洲", character_equivalence: "exact")

      first = run_query_with_manifest(definition, fake_manifest)
      second = run_query_with_manifest(definition, fake_manifest)

      assert_equal 0, first.total
      assert first.truncated
      assert_equal 1, second.total
      assert_equal "中國漢文/clean/周朝/body.txt", second.hits.fetch(0)["path"]
    end
  ensure
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = previous_direct
    ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"] = previous_scan
  end

  test "cached body signatures prioritise likely documents for a new query" do
    previous_direct = ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"]
    previous_scan = ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"]
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = "1"
    ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"] = "1"
    write("中國漢文/clean/周朝/primer.txt", "# TITLE: Primer\n\n人之初，性本善。\n")

    with_manifest(force: true) do |manifest|
      primer = manifest.documents.find { |doc| doc["path"].end_with?("primer.txt") }
      fillers = manifest.documents.reject { |doc| doc.equal?(primer) }.first(2)
      one_doc_manifest = Struct.new(:documents) do
        def filtered(_filters) = documents
      end.new([primer])
      broad_manifest = Struct.new(:documents) do
        def filtered(_filters) = documents
      end.new([*fillers, primer])

      run_query_with_manifest(
        CorpusSearch::SearchDefinition.new(query_text: "人之初", character_equivalence: "exact"),
        one_doc_manifest
      )
      page = run_query_with_manifest(
        CorpusSearch::SearchDefinition.new(
          mode: "proximity",
          terms: %w[人 之 初 性 本 善],
          maximum_span: 20,
          order: "entered",
          character_equivalence: "exact"
        ),
        broad_manifest
      )

      assert_equal 1, page.total
      assert_equal "中國漢文/clean/周朝/primer.txt", page.hits.fetch(0)["path"]
      assert_equal 1, page.scanned_files
    end
  ensure
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = previous_direct
    ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"] = previous_scan
  end

  test "path and title hints prioritise a likely received text" do
    previous_direct = ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"]
    previous_scan = ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"]
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = "1"
    ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"] = "1"
    write("中國漢文/clean/周朝/關雎/關雎.txt", "# TITLE: 關雎\n\n關關雎鳩，在河之洲。\n")

    with_manifest(force: true) do |manifest|
      target = manifest.documents.find { |doc| doc["path"].end_with?("關雎/關雎.txt") }
      filler = manifest.documents.find { |doc| doc["path"].end_with?("proximity.txt") }
      fake_manifest = Struct.new(:documents) do
        def filtered(_filters) = documents
      end.new([filler, target])

      page = run_query_with_manifest(
        CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩", character_equivalence: "exact"),
        fake_manifest
      )

      assert_equal 1, page.total
      assert_equal "中國漢文/clean/周朝/關雎/關雎.txt", page.hits.fetch(0)["path"]
      assert_equal 1, page.scanned_files
    end
  ensure
    ENV["CORPUS_SEARCH_DIRECT_SCAN_LIMIT"] = previous_direct
    ENV["CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT"] = previous_scan
  end

  private

  def run_query(definition)
    with_manifest { |manifest| run_query_with_manifest(definition, manifest) }
  end

  def run_query_with_manifest(definition, manifest)
    presentation = CorpusSearch::PresentationOptions.new
    query = CorpusSearch::Query.new(
      search_definition: definition,
      presentation_options: presentation,
      requested: true
    )

    CorpusSearch::Runner.new(
      query: query,
      manifest: manifest,
      cache_store: @cache_store
    ).page
  end

  def with_manifest(force: true)
    Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      manifest = quietly do
        CorpusSearch::Manifest.load(
          root: @corpus_root,
          cache_store: @cache_store,
          refresh: true,
          force: force
        )
      end
      yield manifest
    end
  end

  def default_scoped_document_count
    with_manifest { |manifest| manifest.filtered({}).length }
  end

  def write(relative, content)
    path = @corpus_root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end

  def quietly
    old = ENV["CORPUS_SEARCH_SILENT"]
    ENV["CORPUS_SEARCH_SILENT"] = "1"
    yield
  ensure
    ENV["CORPUS_SEARCH_SILENT"] = old
  end
end
