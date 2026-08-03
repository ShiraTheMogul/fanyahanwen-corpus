# frozen_string_literal: true

require "minitest/autorun"
require "rake"

class CorpusMetadataIdRakeIntegrationTest < Minitest::Test
  def test_manifest_rebuild_depends_on_metadata_id_repair
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/corpus_metadata_ids.rake", __dir__)

    prerequisites = Rake::Task["corpus_search:rebuild_manifest"].prerequisites
    assert_includes prerequisites, "corpus_metadata_ids:repair"
  ensure
    Rake.application = Rake::Application.new
  end
end
