# frozen_string_literal: true

require_relative "../test_helper"

class CorpusViewerWorkPaginationTest < ActiveSupport::TestCase
  FakePage = Struct.new(:paths, :page, :per_page, :total, :total_pages, keyword_init: true)

  test "large work pages are adapted to the bounded directory list UI" do
    base = Class.new do
      attr_reader :kind, :children, :directory_page

      private

      def load_work_folder_index(fs:, metadata_store:, work_listing:)
        @kind = :work_index
        @rel_path = "中國漢文/clean/漢朝/西漢/史記"
        @work_page = CorpusViewerWorkPaginationTest::FakePage.new(
          paths: [
            "中國漢文/clean/漢朝/西漢/史記/史記__juan_001.txt",
            "中國漢文/clean/漢朝/西漢/史記/史記__juan_002.txt"
          ],
          page: 1,
          per_page: 100,
          total: 130,
          total_pages: 2
        )
        @work_document_paths = @work_page.paths
        @work_folder_view = true
      end
    end
    base.prepend(CorpusViewerWorkPagination)
    object = base.new
    object.send(:load_work_folder_index, fs: nil, metadata_store: nil, work_listing: nil)

    assert_equal :dir, object.kind
    assert_equal %w[史記__juan_001.txt 史記__juan_002.txt], object.children
    assert_equal 130, object.directory_page.raw_total
    assert_equal 2, object.directory_page.total_pages
  end
  test "work-title search is only activated at the Corpus Viewer root" do
    base = Class.new do
      attr_accessor :params
    end
    base.prepend(CorpusViewerWorkPagination)
    object = base.new

    object.params = { path: "", catalogue_q: "史記" }
    assert object.send(:work_title_search_requested?)

    object.params = { path: "中國漢文/clean", catalogue_q: "史記" }
    refute object.send(:work_title_search_requested?)

    object.params = { path: "", catalogue_q: "   " }
    refute object.send(:work_title_search_requested?)
  end

end
