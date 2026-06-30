require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchWarmTermListTest < ActiveSupport::TestCase
  FakeEntry = Struct.new(:headword) do
    def single_character?
      headword.each_char.count == 1
    end
  end
  FakeGrammarStore = Struct.new(:all)

  setup do
    @directory = Pathname.new(Dir.mktmpdir("warm-term-list"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    @csv_path = @directory.join("frequency.csv")
    @csv_path.write("chars,n,rank\n之,100,1\n不,90,2\n而,80,3\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "combines the ranked list, grammar catalogue, and existing indexes" do
    existing = CorpusSearch::TermIndex.fresh_payload_for("弗")
    @cache_store.write_json(CorpusSearch::TermIndex.cache_path_for("弗"), existing)
    grammar_store = FakeGrammarStore.new([FakeEntry.new("之"), FakeEntry.new("爾"), FakeEntry.new("爾們")])

    terms = CorpusSearch::WarmTermList.load(
      limit: 2,
      cache_store: @cache_store,
      grammar_store: grammar_store,
      csv_path: @csv_path
    )

    assert_equal %w[之 不 爾 弗], terms
  end
end
