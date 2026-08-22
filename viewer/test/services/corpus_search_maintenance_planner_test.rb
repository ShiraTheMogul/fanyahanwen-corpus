# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class CorpusSearchMaintenancePlannerTest < ActiveSupport::TestCase
  test "generated metadata id registry is excluded from manifest change detection" do
    planner = CorpusSearch::MaintenancePlanner.allocate
    planner.instance_variable_set(:@corpus_relative, "corpus")

    assert planner.send(:generated_corpus_path?, "corpus/.metadata_id_registry.csv")
    refute planner.send(:generated_corpus_path?, "corpus/中國漢文/clean/唐/foo.txt")
  end

  test "manifest relevance is limited to txt bodies and metadata json" do
    planner = CorpusSearch::MaintenancePlanner.allocate
    planner.instance_variable_set(:@corpus_relative, "corpus")

    assert planner.send(:manifest_relevant_path?, "corpus/日本漢文/clean/平安/a.txt")
    assert planner.send(:manifest_relevant_path?, "corpus/日本漢文/clean/平安/metadata.json")
    refute planner.send(:manifest_relevant_path?, "corpus/日本漢文/clean/平安/source.pdf")
  end

  test "dirty path fingerprints distinguish repeated edits to the same path" do
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("sample.txt")
      path.write("one")
      planner = CorpusSearch::MaintenancePlanner.allocate
      first = planner.send(:stat_fingerprint, path)
      sleep 0.01
      path.write("two and longer")
      second = planner.send(:stat_fingerprint, path)
      refute_equal first, second
    end
  end
end

class CorpusSearchMaintenancePlannerFastPathTest < ActiveSupport::TestCase
  test "missing baseline can choose full plan without scanning dirty paths" do
    planner = CorpusSearch::MaintenancePlanner.allocate
    planner.instance_variable_set(:@read_state, {})

    planner.define_singleton_method(:read_state) { {} }
    planner.define_singleton_method(:manifest_cache_current?) { true }
    planner.define_singleton_method(:current_state) do |include_dirty: true|
      raise "dirty scan should have been skipped" if include_dirty
      { "version" => CorpusSearch::MaintenancePlanner::VERSION, "dirty_paths" => {} }
    end

    plan = planner.plan
    assert_equal :full, plan.manifest_action
    assert_includes plan.reasons, "incremental maintenance baseline is missing or stale"
  end

  test "untracked clean directory is manifest relevant without enumerating every child" do
    planner = CorpusSearch::MaintenancePlanner.allocate
    planner.instance_variable_set(:@corpus_relative, "corpus")

    assert planner.send(:manifest_relevant_path?, "corpus/日本漢文/clean/新規作品/")
    refute planner.send(:manifest_relevant_path?, "corpus/日本漢文/raw/new-download/")
  end
end
