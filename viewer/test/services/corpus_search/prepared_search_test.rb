require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchPreparedSearchTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("prepared-search"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory)
    @query = CorpusSearch::Query.from_params(
      "mode" => "exact",
      "q" => "仁",
      "punctuation" => "ignore",
      "characters" => "common",
      "roles" => ["canonical"]
    )
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "new prepared searches record the current schema version" do
    prepared = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)

    assert_equal CorpusSearch::PreparedSearch::RECORD_VERSION, prepared.record_version
    assert prepared.current_record_version?
  end

  test "writes a frozen record once and refuses later completion changes" do
    prepared = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)
    snapshot = { "snapshot_id" => "snapshot-1" }
    artifacts = [{ "path" => "results.csv", "bytes" => 10, "sha256" => "abc" }]

    assert prepared.complete!(
      progress: { "hits_found" => 2 },
      outputs: { "zip_path" => "/tmp/result.zip" },
      corpus_snapshot: snapshot,
      artifact_manifest: artifacts
    )
    assert prepared.frozen?
    assert_equal "snapshot-1", prepared.frozen_record.dig("corpus_snapshot", "snapshot_id")

    assert_not prepared.complete!(
      progress: { "hits_found" => 999 },
      outputs: { "zip_path" => "/tmp/changed.zip" },
      corpus_snapshot: { "snapshot_id" => "changed" },
      artifact_manifest: []
    )

    prepared.load!
    assert_equal 2, prepared.payload.dig("progress", "hits_found")
    assert_equal "/tmp/result.zip", prepared.payload.dig("outputs", "zip_path")
    assert_equal "snapshot-1", prepared.frozen_record.dig("corpus_snapshot", "snapshot_id")
  end

  test "treats corrupt status JSON as unavailable" do
    prepared = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)
    status_path = @cache_store.absolute(File.join("prepared", prepared.id, "status.json"))
    status_path.write("{not-json")

    assert_nil CorpusSearch::PreparedSearch.find(
      id: prepared.id,
      key: prepared.key,
      cache_store: @cache_store
    )
    assert_nil CorpusSearch::PreparedSearch.find_internal(
      id: prepared.id,
      cache_store: @cache_store
    )
  end

  test "stores comparison and source record identifiers" do
    source = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)
    comparison = CorpusSearch::ComparisonDefinition.new(
      dimension: "nation",
      left_group: "日本",
      right_group: "越南"
    )

    prepared = CorpusSearch::PreparedSearch.create!(
      query: @query,
      comparison: comparison,
      source_prepared: source,
      cache_store: @cache_store
    )

    assert_equal source.id, prepared.source_prepared_id
    assert_equal comparison.to_h, prepared.comparison.to_h
  end
  test "retries transient status-file rename failures" do
    prepared = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)
    calls = 0
    original_rename = File.method(:rename)
    previous_retries = ENV["CORPUS_SEARCH_ATOMIC_WRITE_RETRIES"]
    previous_sleep = ENV["CORPUS_SEARCH_ATOMIC_WRITE_RETRY_SLEEP"]
    ENV["CORPUS_SEARCH_ATOMIC_WRITE_RETRIES"] = "3"
    ENV["CORPUS_SEARCH_ATOMIC_WRITE_RETRY_SLEEP"] = "0"

    File.singleton_class.define_method(:rename) do |source, target|
      if target.to_s.end_with?("status.json") && calls < 2
        calls += 1
        raise Errno::EACCES, "simulated transient lock"
      end

      original_rename.call(source, target)
    end

    assert prepared.update!(progress: { "stage" => "retry_test" })
    prepared.load!
    assert_equal "retry_test", prepared.payload.dig("progress", "stage")
    assert_equal 2, calls
  ensure
    File.singleton_class.define_method(:rename) { |source, target| original_rename.call(source, target) } if defined?(original_rename) && original_rename
    ENV["CORPUS_SEARCH_ATOMIC_WRITE_RETRIES"] = previous_retries
    ENV["CORPUS_SEARCH_ATOMIC_WRITE_RETRY_SLEEP"] = previous_sleep
  end

  test "tracks and clears full search client keys" do
    client = Struct.new(:to_h).new({ "ip_key" => "ip-1", "cookie_key" => "cookie-1" })
    prepared = CorpusSearch::PreparedSearch.create!(
      query: @query,
      cache_store: @cache_store,
      full_search: true,
      client_identity: client
    )

    assert prepared.full_search?
    assert prepared.active_full_search?
    assert CorpusSearch::PreparedSearch.active_full_search_for_client?(client, cache_store: @cache_store)

    prepared.mark_downloaded!
    prepared.load!

    assert prepared.downloaded?
    assert_empty prepared.payload.fetch("client")
    assert_not CorpusSearch::PreparedSearch.active_full_search_for_client?(client, cache_store: @cache_store)
  end

  test "cancel request turns an active full search into a cancellation state" do
    prepared = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store, full_search: true)

    assert prepared.request_cancel!
    prepared.load!
    assert prepared.cancel_requested?
    assert_equal "cancel_requested", prepared.status

    assert prepared.cancel!(message: "stopped")
    prepared.load!
    assert prepared.cancelled?
    assert_not prepared.active_full_search?
  end

  test "temporary notification email is deleted after send and email key after download" do
    prepared = CorpusSearch::PreparedSearch.create!(
      query: @query,
      cache_store: @cache_store,
      full_search: true,
      notification_email: "Reader@Example.Org"
    )

    prepared.load!
    assert_equal "Reader@Example.Org", prepared.notification_email
    assert_match(/\A[0-9a-f]{64}\z/, prepared.payload.dig("notification", "email_key"))
    assert prepared.notification_pending?

    assert prepared.mark_notification_sent!
    prepared.load!

    assert_nil prepared.notification_email
    assert_nil prepared.payload.dig("notification", "email_encrypted")
    assert_match(/\A[0-9a-f]{64}\z/, prepared.payload.dig("notification", "email_key"))
    assert_not prepared.notification_pending?

    assert prepared.mark_downloaded!
    prepared.load!

    assert_nil prepared.payload.dig("notification", "email_key")
  end

  test "full search throttle can match the optional email key" do
    email = "reader@example.org"
    prepared = CorpusSearch::PreparedSearch.create!(
      query: @query,
      cache_store: @cache_store,
      full_search: true,
      notification_email: email
    )

    assert CorpusSearch::PreparedSearch.active_full_search_for_client?(
      Struct.new(:to_h).new({}),
      cache_store: @cache_store,
      email_key: CorpusSearch::ClientIdentity.email_key(email)
    )

    prepared.cancel!(message: "test cleanup")
    assert_not CorpusSearch::PreparedSearch.active_full_search_for_client?(
      Struct.new(:to_h).new({}),
      cache_store: @cache_store,
      email_key: CorpusSearch::ClientIdentity.email_key(email)
    )
  end

end
