require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchDocumentStatsCacheTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("document-stats-cache"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory)
    @document = {
      "id" => "doc-1",
      "path" => "中國漢文/clean/text.txt",
      "fingerprint" => "10:1.0"
    }
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "shares body statistics across searches while keeping punctuation counts separate" do
    cache = CorpusSearch::DocumentStatsCache.new(cache_store: @cache_store)
    cache.write(
      @document,
      punctuation: "ignore",
      searchable_characters: 12,
      body_fingerprint: "a" * 64
    )
    cache.write(
      @document,
      punctuation: "respect",
      searchable_characters: 15,
      body_fingerprint: "a" * 64
    )
    cache.close

    reloaded = CorpusSearch::DocumentStatsCache.new(cache_store: @cache_store)
    ignored = reloaded.fetch(@document, punctuation: "ignore")
    respected = reloaded.fetch(@document, punctuation: "respect")

    assert_equal 12, ignored.searchable_characters
    assert_equal 15, respected.searchable_characters
    assert_equal "a" * 64, ignored.body_fingerprint
    reloaded.close
  end

  test "rejects statistics when the manifest fingerprint changes" do
    cache = CorpusSearch::DocumentStatsCache.new(cache_store: @cache_store)
    cache.write(
      @document,
      punctuation: "ignore",
      searchable_characters: 12,
      body_fingerprint: "a" * 64
    )
    cache.close

    changed = @document.merge("fingerprint" => "11:2.0")
    reloaded = CorpusSearch::DocumentStatsCache.new(cache_store: @cache_store)
    assert_nil reloaded.fetch(changed, punctuation: "ignore")
    reloaded.close
  end
  test "retains a character signature for later candidate prioritisation" do
    cache = CorpusSearch::DocumentStatsCache.new(cache_store: @cache_store)
    bloom = CorpusSearch::CharacterBloom.build("人之初，性本善。")
    cache.write(
      @document,
      punctuation: "ignore",
      searchable_characters: 6,
      body_fingerprint: "a" * 64,
      character_bloom: bloom
    )
    cache.save!

    matching = cache.matching_document_ids(
      term_patterns: ["性本善".chars.map { |character| Set[character] }]
    )
    missing = cache.matching_document_ids(
      term_patterns: ["關雎".chars.map { |character| Set[character] }]
    )

    assert_includes matching, "doc-1"
    refute_includes missing, "doc-1"
    cache.close
  end

end
