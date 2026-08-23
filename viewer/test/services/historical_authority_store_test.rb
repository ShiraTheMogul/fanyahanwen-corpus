# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "tmpdir"

class HistoricalAuthorityStoreTest < ActiveSupport::TestCase
  test "automatic authority availability requires a searchable index" do
    store = HistoricalAuthorityStore.allocate

    store.stub(:lookup_available?, false) do
      store.stub(:historical_available?, false) do
        assert_equal false, store.available?
      end
    end

    store.stub(:lookup_available?, true) do
      store.stub(:historical_available?, false) do
        assert_equal true, store.available?
      end
    end

    store.stub(:lookup_available?, false) do
      store.stub(:historical_available?, true) do
        assert_equal true, store.available?
      end
    end
  end

  test "CBDB lookup availability rejects an older on-disk schema version" do
    Dir.mktmpdir do |directory|
      cbdb_path = Pathname(directory).join("cbdb.sqlite3")
      lookup_path = Pathname(directory).join("cbdb-lookup.sqlite3")
      cbdb_path.binwrite("cbdb")
      lookup_path.binwrite("lookup")
      sha = Digest::SHA256.file(cbdb_path).hexdigest

      build_store = lambda do
        HistoricalAuthorityStore.new(
          cbdb_path: cbdb_path,
          cbdb_release: { "sha256" => sha },
          lookup_path: lookup_path,
          historical_path: nil,
          cache_store: Object.new,
          logger: nil
        )
      end

      stale = { "version" => CbdbLookupIndex::VERSION - 1, "source_sha256" => sha }
      CbdbLookupIndex.stub(:metadata, stale) do
        assert_equal false, build_store.call.lookup_available?
      end

      current = { "version" => CbdbLookupIndex::VERSION, "source_sha256" => sha }
      CbdbLookupIndex.stub(:metadata, current) do
        assert_equal true, build_store.call.lookup_available?
      end
    end
  end
end
