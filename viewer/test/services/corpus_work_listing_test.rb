require_relative "../test_helper"
require "fileutils"
require "json"
require "tmpdir"

class CorpusWorkListingTest < ActiveSupport::TestCase
  UTF8_BOM = "\xEF\xBB\xBF".force_encoding(Encoding::UTF_8).freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("corpus-work-listing"))
    @work = @root.join("work")
    @work.mkdir
    @fs = CorpusFs.new(root: @root)
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "lists metadata documents without reading their bodies" do
    documents = 25.times.map { |index| { "file" => format("juan_%02d.txt", index + 1) } }
    write_metadata(documents)
    listing = build_listing

    assert listing.work_folder?
    assert_equal 25, listing.document_count

    page = listing.page(page: 2, per_page: 10)
    assert_equal 25, page.total
    assert_equal 3, page.total_pages
    assert_equal "work/juan_11.txt", page.paths.first
    assert_equal "work/juan_20.txt", page.paths.last
    assert_equal "juan_11", page.documents.first.label
  end

  test "does not treat a descendant directory as the metadata-owning work" do
    write_metadata([{ "file" => "one.txt" }])
    @work.join("nested").mkdir
    nested = CorpusWorkListing.new(
      root: @root,
      fs: @fs,
      metadata_store: CorpusMetadataStore.new(root: @root, fs: @fs),
      rel_path: "work/nested"
    )

    refute nested.work_folder?
  end

  test "multi-document works always use the document index" do
    @work.join("small.txt").binwrite("a" * 128)
    @work.join("large.txt").binwrite("b" * 2048)
    write_metadata([{ "file" => "small.txt" }, { "file" => "large.txt" }])

    refute build_listing.inline_renderable?(document_limit: 20, byte_limit: 4096)
  end

  test "single-document works still use the byte budget" do
    @work.join("small.txt").binwrite("a" * 128)
    write_metadata([{ "file" => "small.txt" }])
    listing = build_listing

    assert listing.inline_renderable?(document_limit: 20, byte_limit: 4096)
    refute listing.inline_renderable?(document_limit: 20, byte_limit: 64)
  end

  test "puts 序說 first and sorts 論語 chapter numbers" do
    write_metadata([
      { "file" => "論語__先進第十一.txt", "page_title" => "論語/先進第十一" },
      { "file" => "論語__八佾第三.txt", "page_title" => "論語/八佾第三" },
      { "file" => "論語__堯曰第二十.txt", "page_title" => "論語/堯曰第二十" },
      { "file" => "論語__學而第一.txt", "page_title" => "論語/學而第一" },
      { "file" => "論語__序說.txt", "page_title" => "論語/序說" },
      { "file" => "論語__爲政第二.txt", "page_title" => "論語/爲政第二" }
    ], title: "論語")

    assert_equal [
      "work/論語__序說.txt",
      "work/論語__學而第一.txt",
      "work/論語__爲政第二.txt",
      "work/論語__八佾第三.txt",
      "work/論語__先進第十一.txt",
      "work/論語__堯曰第二十.txt"
    ], listing_paths
  end

  test "treats numbered prefaces as front matter" do
    write_metadata([
      { "file" => "卷一.txt" },
      { "file" => "序二.txt" },
      { "file" => "序一.txt" },
      { "file" => "卷二.txt" }
    ])

    assert_equal ["序二", "序一", "卷一", "卷二"], listing_labels
  end

  test "promotes generated-file front matter and keeps numbered volumes numerical" do
    write_metadata([
      { "file" => "中說__juan_01.txt", "page_title" => "中說/卷一" },
      { "file" => "中說__juan_10.txt", "page_title" => "中說/卷十" },
      { "file" => "中說__juan_02.txt", "page_title" => "中說/卷二" },
      { "file" => "中說__juan_11.txt", "page_title" => "中說/序" },
      { "file" => "中說__juan_12.txt", "page_title" => "中說/敘篇" }
    ], title: "中說")

    assert_equal [
      "work/中說__juan_11.txt",
      "work/中說__juan_12.txt",
      "work/中說__juan_01.txt",
      "work/中說__juan_02.txt",
      "work/中說__juan_10.txt"
    ], listing_paths
  end

  test "groups a scrambled numbered family before the next family" do
    write_metadata([
      { "file" => "天演論_juan_1.txt", "page_title" => "天演論/吳序" },
      { "file" => "天演論_juan_10.txt", "page_title" => "天演論/導言七" },
      { "file" => "天演論_juan_11.txt", "page_title" => "天演論/導言八" },
      { "file" => "天演論_juan_2.txt", "page_title" => "天演論/自序" },
      { "file" => "天演論_juan_21.txt", "page_title" => "天演論/論一" },
      { "file" => "天演論_juan_22.txt", "page_title" => "天演論/論二" },
      { "file" => "天演論_juan_3.txt", "page_title" => "天演論/譯例言" },
      { "file" => "天演論_juan_4.txt", "page_title" => "天演論/導言一" },
      { "file" => "天演論_juan_5.txt", "page_title" => "天演論/導言二" },
      { "file" => "天演論_juan_6.txt", "page_title" => "天演論/導言三" }
    ], title: "天演論")

    assert_equal [
      "吳序", "自序", "譯例言",
      "導言一", "導言二", "導言三", "導言七", "導言八",
      "論一", "論二"
    ], listing_labels
  end

  test "uses page-title hierarchy to keep repeated chapter sequences separate" do
    write_metadata([
      { "file" => "三稿1.txt", "page_title" => "大上海都市計劃/三稿/第一章" },
      { "file" => "三稿3.txt", "page_title" => "大上海都市計劃/三稿/第三章" },
      { "file" => "三稿2.txt", "page_title" => "大上海都市計劃/三稿/第二章" },
      { "file" => "二稿1.txt", "page_title" => "大上海都市計劃/二稿/第一章" },
      { "file" => "二稿3.txt", "page_title" => "大上海都市計劃/二稿/第三章" },
      { "file" => "二稿2.txt", "page_title" => "大上海都市計劃/二稿/第二章" }
    ], title: "大上海都市計劃")

    assert_equal [
      "三稿 / 第一章", "三稿 / 第二章", "三稿 / 第三章",
      "二稿 / 第一章", "二稿 / 第二章", "二稿 / 第三章"
    ], listing_labels
  end

  test "keeps 素問 and 靈樞 as separate volume families" do
    write_metadata([
      { "file" => "a.txt", "page_title" => "黃帝內經/素問第一卷" },
      { "file" => "b.txt", "page_title" => "黃帝內經/素問第三卷" },
      { "file" => "c.txt", "page_title" => "黃帝內經/素問第二卷" },
      { "file" => "d.txt", "page_title" => "黃帝內經/靈樞第一卷" },
      { "file" => "e.txt", "page_title" => "黃帝內經/靈樞第三卷" },
      { "file" => "f.txt", "page_title" => "黃帝內經/靈樞第二卷" }
    ], title: "黃帝內經")

    assert_equal [
      "素問第一卷", "素問第二卷", "素問第三卷",
      "靈樞第一卷", "靈樞第二卷", "靈樞第三卷"
    ], listing_labels
  end

  test "does not disturb an already-correct interleaving of 卷 and 續卷" do
    write_metadata([
      { "file" => "a.txt", "page_title" => "大溪先生文集/卷一" },
      { "file" => "b.txt", "page_title" => "大溪先生文集/續卷一" },
      { "file" => "c.txt", "page_title" => "大溪先生文集/卷二" },
      { "file" => "d.txt", "page_title" => "大溪先生文集/續卷二" },
      { "file" => "e.txt", "page_title" => "大溪先生文集/卷三" }
    ], title: "大溪先生文集")

    assert_equal ["卷一", "續卷一", "卷二", "續卷二", "卷三"], listing_labels
  end

  test "places 附錄卷 after the main volumes" do
    write_metadata([
      { "file" => "a.txt", "page_title" => "拓菴先生文集/卷一" },
      { "file" => "b.txt", "page_title" => "拓菴先生文集/附錄卷一" },
      { "file" => "c.txt", "page_title" => "拓菴先生文集/卷二" },
      { "file" => "d.txt", "page_title" => "拓菴先生文集/附錄卷二" },
      { "file" => "e.txt", "page_title" => "拓菴先生文集/卷三" }
    ], title: "拓菴先生文集")

    assert_equal ["卷一", "卷二", "卷三", "附錄卷一", "附錄卷二"], listing_labels
  end

  test "does not interleave a heavily duplicated numbered family" do
    write_metadata([
      { "file" => "a.txt", "page_title" => "清史稿/卷1" },
      { "file" => "b.txt", "page_title" => "清史稿/卷10" },
      { "file" => "c.txt", "page_title" => "清史稿/卷2" },
      { "file" => "d.txt", "page_title" => "清史稿/卷1" },
      { "file" => "e.txt", "page_title" => "清史稿/卷2" },
      { "file" => "f.txt", "page_title" => "清史稿/卷10" }
    ], title: "清史稿")

    assert_equal ["卷1", "卷10", "卷2", "卷1", "卷2", "卷10"], listing_labels
  end

  test "does not sort arbitrary archaeological identifiers by trailing Arabic digits" do
    write_metadata([
      { "file" => "a.txt", "page_title" => "ASDC｜簡牘｜郭店楚簡｜語叢三70背" },
      { "file" => "b.txt", "page_title" => "ASDC｜簡牘｜郭店楚簡｜語叢三02背" },
      { "file" => "c.txt", "page_title" => "ASDC｜簡牘｜郭店楚簡｜語叢三11背" }
    ], title: "戰國簡牘")

    assert_equal [
      "ASDC｜簡牘｜郭店楚簡｜語叢三70背",
      "ASDC｜簡牘｜郭店楚簡｜語叢三02背",
      "ASDC｜簡牘｜郭店楚簡｜語叢三11背"
    ], listing_labels
  end

  test "fallback files put prefaces first, parts in order, appendices next, and postscripts last" do
    write_metadata([])
    %w[卷之下.txt 卷之上.txt 叙.txt 跋.txt 卷之中.txt 附錄卷二.txt 附錄卷一.txt].each do |name|
      @work.join(name).binwrite("x")
    end

    assert_equal [
      "work/叙.txt",
      "work/卷之上.txt",
      "work/卷之中.txt",
      "work/卷之下.txt",
      "work/附錄卷一.txt",
      "work/附錄卷二.txt",
      "work/跋.txt"
    ], listing_paths
  end

  test "does not promote 卷一序 ahead of the whole-work 序" do
    write_metadata([
      { "file" => "卷二.txt" },
      { "file" => "卷一序.txt" },
      { "file" => "序.txt" },
      { "file" => "卷一.txt" }
    ])

    paths = listing_paths
    assert_equal "work/序.txt", paths.first
    assert_operator paths.index("work/卷一序.txt"), :>, paths.index("work/序.txt")
  end

  private

  def write_metadata(documents, title: "排序測試")
    payload = JSON.generate("title" => title, "documents" => documents)
    @work.join("metadata.json").binwrite(UTF8_BOM + payload.encode(Encoding::UTF_8))
  end

  def build_listing
    CorpusWorkListing.new(
      root: @root,
      fs: @fs,
      metadata_store: CorpusMetadataStore.new(root: @root, fs: @fs),
      rel_path: "work"
    )
  end

  def listing_page
    build_listing.page(page: 1, per_page: 500)
  end

  def listing_paths
    listing_page.paths
  end

  def listing_labels
    listing_page.documents.map(&:label)
  end
end
