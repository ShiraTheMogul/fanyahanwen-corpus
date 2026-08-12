require_relative "../test_helper"
require "fileutils"
require "json"
require "tmpdir"

class CorpusWorkListingTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("corpus-work-listing"))
    @work = @root.join("work")
    @work.mkdir
    documents = 25.times.map { |index| { "file" => format("juan_%02d.txt", index + 1) } }
    @work.join("metadata.json").write(JSON.generate("title" => "Large work", "documents" => documents))

    @fs = CorpusFs.new(root: @root)
    @metadata_store = CorpusMetadataStore.new(root: @root, fs: @fs)
    @listing = CorpusWorkListing.new(
      root: @root,
      fs: @fs,
      metadata_store: @metadata_store,
      rel_path: "work"
    )
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "lists metadata documents without reading their bodies" do
    assert @listing.work_folder?
    assert_equal 25, @listing.document_count

    page = @listing.page(page: 2, per_page: 10)
    assert_equal 25, page.total
    assert_equal 3, page.total_pages
    assert_equal "work/juan_11.txt", page.paths.first
    assert_equal "work/juan_20.txt", page.paths.last
  end

  test "does not treat a descendant directory as the metadata-owning work" do
    @work.join("nested").mkdir
    nested = CorpusWorkListing.new(
      root: @root,
      fs: @fs,
      metadata_store: @metadata_store,
      rel_path: "work/nested"
    )

    refute nested.work_folder?
  end
end

class CorpusWorkListingByteBudgetTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("corpus-work-listing-bytes"))
    @work = @root.join("work")
    @work.mkdir
    @work.join("small.txt").binwrite("a" * 128)
    @work.join("large.txt").binwrite("b" * 2048)
    @work.join("metadata.json").write(JSON.generate(
      "title" => "Two-part work",
      "documents" => [{ "file" => "small.txt" }, { "file" => "large.txt" }]
    ))

    @fs = CorpusFs.new(root: @root)
    @metadata_store = CorpusMetadataStore.new(root: @root, fs: @fs)
    @listing = CorpusWorkListing.new(
      root: @root,
      fs: @fs,
      metadata_store: @metadata_store,
      rel_path: "work"
    )
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "inline rendering is bounded by source bytes as well as document count" do
    assert @listing.inline_renderable?(document_limit: 20, byte_limit: 4096)
    refute @listing.inline_renderable?(document_limit: 20, byte_limit: 1024)
  end
end
