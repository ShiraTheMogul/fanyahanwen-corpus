# frozen_string_literal: true

# Run from the viewer root with:
#
#   bin/rails runner script/atlas_integration_smoke.rb
#
# This script reads the real atlas content but writes only to a temporary copy.

require "fileutils"
require "tmpdir"

class AtlasIntegrationSmoke
  def initialize
    @failures = []
    @warnings = []
  end

  def run
    phase("1/7", "Validate the content registry") { validate_registry }
    phase("2/7", "Load every published article") { validate_articles }
    phase("3/7", "Validate preset corpus searches") { validate_searches }
    phase("4/7", "Render a corpus quotation") { validate_quote_renderer }
    phase("5/7", "Validate an edit submission") { validate_submission }
    phase("6/7", "Publish safely to a temporary copy") { validate_publisher }
    phase("7/7", "Check the manually added routes") { validate_routes }
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

  def store
    @store ||= Atlas::EntryStore.default
  end

  def validate_registry
    store.validate!
    ids = store.all.map(&:id)
    raise "No atlas entries were discovered" if ids.empty?

    puts "      entries=#{ids.length}: #{ids.join(', ')}"
  end

  def validate_articles
    store.all.each do |entry|
      article = store.load(entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
      next unless article.published?

      raise "#{entry.id} has no References section" unless article.document.references_heading?
      puts "      #{entry.id}: #{article.path.relative_path_from(Rails.root)}"
    end
  end

  def validate_searches
    store.all.each do |entry|
      article = store.load(entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
      next unless article.published?

      searches = Atlas::ArticleSearches.for(entry: entry, article_metadata: article.metadata)
      searches.each { |search| Grammar::CorpusSearchDefinition.normalize(search) }
      puts "      #{entry.id}: #{searches.length} preset search(es)"
    end

    raise "Corpus search no longer accepts a polity filter" unless CorpusSearch::QueryParams::METADATA_KEYS.include?("polity")
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

  def validate_submission
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

    raise "Validator selected the wrong target" unless result.target_path == store.article_path(entry)
  end

  def validate_publisher
    Dir.mktmpdir("atlas-integration-smoke") do |directory|
      copied_root = Pathname.new(directory).join("atlas")
      FileUtils.cp_r(store.root, copied_root)
      copied_store = Atlas::EntryStore.new(root: copied_root)
      entry = copied_store.all.find { |candidate| copied_store.article_exists?(candidate) }
      proposed = copied_store.submission_markdown_for(entry)

      final_markdown = Atlas::Publisher.new(
        store: copied_store,
        reviewer_name: "Atlas smoke-test reviewer",
        today: Date.current
      ).publish!(
        entry_id: entry.id,
        locale: Atlas::EntryStore::SOURCE_LOCALE,
        proposed_markdown: proposed,
        credit: { "name" => "Atlas smoke test", "role" => "contributor" }
      )

      final = Grammar::MarkdownDocument.parse(final_markdown)
      raise "Publisher did not preserve CC BY" unless final.metadata["licence"] == "CC BY"
      raise "Publisher did not record the reviewer" unless Array(final.metadata["contributors"]).any? { |row| row["role"] == "editor" }
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

    return if missing.empty?

    message = "Manual atlas routes are still missing: #{missing.join(', ')}. Copy ATLAS_ROUTES_TO_ADD.txt into config/routes.rb."
    @warnings << message
    puts "      WARNING: #{message}"
  end

  def finish
    puts "\n=== Historical Atlas integration result ==="
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
