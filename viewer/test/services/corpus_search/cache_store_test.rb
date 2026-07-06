require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchCacheStoreTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("cache-store"))
    @store = CorpusSearch::CacheStore.new(root: @directory)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "can freeze large read-only JSON payloads" do
    @store.write_json("payload.json.gz", { "documents" => [{ "title" => "同文" }] })

    payload = @store.read_json("payload.json.gz", freeze: true)

    assert payload.frozen?
    assert payload.fetch("documents").frozen?
    assert payload.fetch("documents").first.frozen?
    assert payload.fetch("documents").first.fetch("title").frozen?
  end

  test "keeps mutable JSON as the default for writable caches" do
    @store.write_json("payload.json.gz", { "files" => {} })

    payload = @store.read_json("payload.json.gz")
    payload.fetch("files")["doc"] = { "hits" => [] }

    assert payload.fetch("files").key?("doc")
  end

  test "uses the configured cache root when no explicit root is supplied" do
    configured = @directory.join("configured")

    with_env("CORPUS_SEARCH_CACHE_ROOT" => configured.to_s) do
      store = CorpusSearch::CacheStore.new
      assert_equal configured.expand_path, store.root
    end
  end

  test "uses conservative SQLite journalling on a Windows-mounted WSL path" do
    store = CorpusSearch::CacheStore.allocate
    store.instance_variable_set(:@root, Pathname("/mnt/c/fanya-cache"))

    assert_equal "DELETE", store.sqlite_journal_mode
  end

  private

  def with_env(values)
    previous = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
