# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusAnnotationsControllerTest < ActionController::TestCase
  tests CorpusAnnotationsController

  FakeMetadataStore = Struct.new(:detailed, :search) do
    def document_metadata_for_path(_path) = detailed
    def search_metadata_for_path(_path) = search
  end

  setup do
    @directory = Pathname.new(Dir.mktmpdir("corpus-auto-annotations"))
    @relative_path = "中國漢文/clean/春秋/測試.txt"
    absolute = @directory.join(@relative_path)
    FileUtils.mkdir_p(absolute.dirname)
    absolute.binwrite("\xEF\xBB\xBF".b + "孔子曰".b)
  end

  teardown do
    FileUtils.rm_rf(@directory)
  end

  test "GET auto annotations is owned directly by the routed controller" do
    assert_equal CorpusAnnotationsController, CorpusAnnotationsController.instance_method(:show).owner
  end

  test "GET auto annotations sends the displayed corpus body through the historical cache and returns its schema" do
    metadata_store = FakeMetadataStore.new(
      { "period" => "春秋", "corpus_root" => "中國漢文" },
      { "year_start" => -500, "year_end" => -450 }
    )
    authority_store = Object.new
    captured = nil
    result = HistoricalAutoAnnotationCache::Result.new(
      items: [{ "start" => 0, "end" => 2, "kind" => "person", "text" => "孔子" }],
      context: { "year_start" => -500, "year_end" => -450 },
      authority: { "cbdb_lookup_available" => true, "historical_available" => false },
      cached: false
    )

    fetcher = lambda do |**arguments|
      captured = arguments
      result
    end

    controller_root = @directory.to_s
    @controller.define_singleton_method(:corpus_root) { controller_root }

    CorpusMetadataStore.stub(:new, metadata_store) do
      HistoricalAuthorityStore.stub(:default, authority_store) do
        HistoricalAutoAnnotationCache.stub(:fetch, fetcher) do
          get :show, params: {
            auto: "1",
            path: @relative_path,
            source_path: @relative_path
          }
        end
      end
    end

    assert_response :success
    payload = JSON.parse(response.body)

    assert_equal "孔子曰", captured.fetch(:text)
    assert_equal "春秋", captured.fetch(:metadata).fetch("period")
    assert_equal(-500, captured.fetch(:metadata).fetch("year_start"))
    assert_equal @relative_path, captured.fetch(:cache_identity).split("\0").first
    assert_same authority_store, captured.fetch(:store)

    assert_equal 1, payload.fetch("version")
    assert_equal "孔子", payload.fetch("items").first.fetch("text")
    assert_equal true, payload.fetch("authority").fetch("cbdb_lookup_available")
    assert_equal false, payload.fetch("cached")
    assert_not payload.key?("auto_items")
    assert_not payload.key?("auto_authority")
  end
  test "automatic annotation diagnostic line names the matches and their offsets" do
    result = HistoricalAutoAnnotationCache::Result.new(
      items: [{
        "start" => 42, "end" => 44, "kind" => "person", "text" => "孔子",
        "confidence" => "high", "authority_source" => "cbdb"
      }],
      context: {}, authority: {}, cached: true
    )

    line = @controller.send(:automatic_historical_annotation_log_line, @relative_path, result)
    assert_includes line, "matches=1"
    assert_includes line, "孔子[person:42-44:high:cbdb]"
    assert_includes line, "cached=true"
  end

end
