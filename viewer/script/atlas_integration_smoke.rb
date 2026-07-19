# frozen_string_literal: true

# Run from the viewer root with:
#
#   bin/rails runner script/atlas_integration_smoke.rb
#
# Reads the real catalogue and articles. Publication is tested only in a
# temporary copy.

require "benchmark"
require "fileutils"
require "tmpdir"

class AtlasIntegrationSmoke
  def initialize
    @failures = []
    @warnings = []
  end

  def run
    phase("1/10", "Validate the prepared catalogue") { validate_catalogue }
    phase("2/10", "Validate macro-region periodisation") { validate_periodisation }
    phase("3/10", "Benchmark indexed lookups") { benchmark_catalogue }
    phase("4/10", "Load every published article") { validate_articles }
    phase("5/10", "Validate preset corpus searches") { validate_searches }
    phase("6/10", "Render a corpus quotation") { validate_quote_renderer }
    phase("7/10", "Validate an edit submission") { validate_edit_submission }
    phase("8/10", "Validate creation for a metadata-only polity") { validate_create_submission }
    phase("9/10", "Publish safely to a temporary copy") { validate_publisher }
    phase("10/10", "Check the existing routes") { validate_routes }
    finish
  end

  private

  def phase(number, label)
    puts "\n[#{number}] #{label}"
    yield
    puts "      PASS"
  rescue StandardError => e
    @failures << "#{label}: #{e.class}: #{e.message}"
    puts "      FAIL: #{e.class}: #{e.message}"
  end

  def catalogue
    @catalogue ||= Atlas::Catalogue.default
  end

  def store
    @store ||= Atlas::EntryStore.default
  end

  def validate_catalogue
    catalogue.validate!
    store.validate!
    entries = store.all
    raise "No atlas entries were discovered" if entries.empty?
    raise "The Shang polity inventory is incomplete" unless entries.count { |entry| entry.corpus_paths.any? { |path| path.start_with?("中國漢文/clean/商殷朝/") } } == 53

    published = entries.count { |entry| store.article_exists?(entry) }
    puts "      entries=#{entries.length}, published_articles=#{published}, source=#{catalogue.source}"
  end

  def validate_periodisation
    regions = catalogue.macro_regions
    raise "No macro-regions were compiled" if regions.empty?
    raise "China macro-region is missing" unless catalogue.macro_region("中國")
    raise "Shang period is missing" unless catalogue.period("中國", "商殷朝")
    raise "Japanese macro-region is missing" unless catalogue.macro_region("日本")

    periods = regions.sum { |region| Array(region["periods"]).length }
    puts "      macro_regions=#{regions.length}, periods=#{periods}"
  end

  def benchmark_catalogue
    sample = store.all.first(100)
    lookup_time = Benchmark.realtime do
      100.times { sample.each { |entry| raise "lookup failed" unless store.find(entry.id) } }
    end
    browse_time = Benchmark.realtime do
      100.times do
        catalogue.macro_regions.each do |region|
          catalogue.periods_for(region["id"]).each do |period|
            catalogue.entries_for(macro_region_id: region["id"], period_id: period["id"])
          end
        end
      end
    end

    raise "Indexed lookups are too slow: #{lookup_time.round(3)}s" if lookup_time > 1.0
    raise "Period traversal is too slow: #{browse_time.round(3)}s" if browse_time > 2.0
    puts format("      lookups=%.3fs, period_traversals=%.3fs", lookup_time, browse_time)
  end

  def validate_articles
    published = 0
    store.all.each do |entry|
      article = store.load(entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
      next unless article.published?

      raise "#{entry.id} has no References section" unless article.document.references_heading?
      published += 1
    end
    raise "No atlas articles were published" if published.zero?

    puts "      published_articles=#{published}"
  end

  def validate_searches
    folder_scoped = 0
    store.all.each do |entry|
      article = store.load(entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
      searches = Atlas::ArticleSearches.for(entry: entry, article_metadata: article.metadata)
      searches.each do |search|
        normalized = Grammar::CorpusSearchDefinition.normalize(search)
        folder_scoped += 1 if Array(normalized["folders"]).any?
      end
    end

    raise "Corpus search no longer accepts a polity filter" unless CorpusSearch::QueryParams::METADATA_KEYS.include?("polity")
    raise "No atlas preset uses the corpus folder scope" if folder_scoped.zero?
    puts "      folder_scoped_presets=#{folder_scoped}"
  end

  def validate_quote_renderer
    document = Grammar::MarkdownDocument.parse(<<~MARKDOWN)
      ---
      title: Atlas quotation smoke test
      ---

      ## Evidence

      {% corpus_quote path="中國漢文/clean/example.txt" text="大邑商受年" highlight="商|受年" source="Example corpus text" %}

      ## References

      - Smoke-test reference.
    MARKDOWN

    html = Grammar::MarkdownRenderer.render(document)
    raise "Quotation figure was not rendered" unless html.include?("grammar-corpus-quote")
    raise "Corpus-viewer link was not rendered" unless html.include?("/corpus_viewer/")
    raise "Highlighted text was not rendered" unless html.include?("<mark>")
  end

  def validate_edit_submission
    entry = store.all.find { |candidate| store.article_exists?(candidate, locale: Atlas::EntryStore::SOURCE_LOCALE) }
    raise "No published source article is available for an edit test" unless entry

    markdown = store.submission_markdown_for(entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
    result = Atlas::SubmissionValidator.new(store: store).validate!(
      entry_id: entry.id,
      action: "edit",
      locale: Atlas::EntryStore::SOURCE_LOCALE,
      raw_markdown: markdown,
      public_name: "Atlas smoke test",
      orcid: "",
      credit_role: "contributor",
      licence_agreed: true
    )

    raise "Validator selected the wrong edit target" unless result.target_path == store.article_path(entry)
  end

  def validate_create_submission
    entry = store.all.find { |candidate| !store.article_exists?(candidate, locale: Atlas::EntryStore::SOURCE_LOCALE) }
    raise "No metadata-only polity is available for a create test" unless entry

    markdown = store.submission_markdown_for(entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
    result = Atlas::SubmissionValidator.new(store: store).validate!(
      entry_id: entry.id,
      action: "create",
      locale: Atlas::EntryStore::SOURCE_LOCALE,
      raw_markdown: markdown,
      public_name: "Atlas smoke test",
      orcid: "",
      credit_role: "author",
      licence_agreed: true
    )

    raise "Validator selected the wrong create target" unless result.target_path == store.article_path(entry)
  end

  def validate_publisher
    Dir.mktmpdir("atlas-integration-smoke") do |directory|
      copied_root = Pathname.new(directory).join("atlas")
      FileUtils.cp_r(store.root, copied_root)
      copied_store = Atlas::EntryStore.new(root: copied_root, catalogue: catalogue)
      entry = copied_store.all.find { |candidate| !copied_store.article_exists?(candidate) }
      proposed = copied_store.submission_markdown_for(entry)

      final_markdown = Atlas::Publisher.new(
        store: copied_store,
        reviewer_name: "Atlas smoke-test reviewer",
        today: Date.current
      ).publish!(
        entry_id: entry.id,
        locale: Atlas::EntryStore::SOURCE_LOCALE,
        proposed_markdown: proposed,
        credit: { "name" => "Atlas smoke test", "role" => "author" }
      )

      final = Grammar::MarkdownDocument.parse(final_markdown)
      raise "Publisher did not preserve CC BY" unless final.metadata["licence"] == "CC BY"
      raise "Publisher did not record the reviewer" unless Array(final.metadata["contributors"]).any? { |row| row["role"] == "editor" }
      raise "Publisher did not create the article" unless copied_store.article_path(entry).file?
    end
  end

  def validate_routes
    expected = {
      ["GET", "/atlas"] => ["atlas", "index"],
      ["POST", "/atlas/preview"] => ["atlas", "preview"],
      ["GET", "/atlas/shang/template"] => ["atlas", "template"],
      ["GET", "/atlas/shang"] => ["atlas", "show"]
    }

    missing = expected.filter_map do |(method, path), (controller, action)|
      result = Rails.application.routes.recognize_path(path, method: method.downcase.to_sym)
      next if result[:controller] == controller && result[:action] == action

      "#{method} #{path}"
    rescue ActionController::RoutingError
      "#{method} #{path}"
    end

    raise "Atlas routes are missing: #{missing.join(', ')}" if missing.any?
  end

  def finish
    puts "\n=== Atlas integration result ==="
    @warnings.each { |warning| puts "WARNING: #{warning}" }

    if @failures.empty?
      puts "PASS: all executable checks succeeded."
      exit 0
    end

    @failures.each { |failure| puts "FAIL: #{failure}" }
    exit 1
  end
end

AtlasIntegrationSmoke.new.run
