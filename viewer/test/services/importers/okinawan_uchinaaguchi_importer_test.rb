require_relative "../../test_helper"

class OkinawanUchinaaguchiImporterTest < ActiveSupport::TestCase
  setup do
    @importer = Importers::OkinawanUchinaaguchiImporter.new(
      main_path: "/tmp/okinawa_01.xlsx",
      index_path: "/tmp/okinawa_02.xlsx",
      verbose: false
    )
  end

  test "accepts one bracketed Han character" do
    assert_equal "藍", @importer.send(:exact_single_han_character, "〔藍〕")
    assert_equal "𠀀", @importer.send(:exact_single_han_character, "〔𠀀〕")
  end

  test "does not turn compounds into character readings" do
    assert_nil @importer.send(:exact_single_han_character, "〔愛育〕")
    assert_nil @importer.send(:exact_single_han_character, "沖縄")
  end

  test "extracts direct Okinawan forms before examples" do
    accepted, rejected = @importer.send(
      :extract_candidates,
      "?asi，hwisja，(敬語)mihwisja→?asihwisja，/ ～の甲 hwisjanaa"
    )

    assert_equal ["?asi", "hwisja", "mihwisja"], accepted
    assert_empty rejected
  end

  test "keeps index forms even when source notation is visibly incomplete" do
    accepted, = @importer.send(:extract_candidates, "●iCi，?usju.")

    assert_equal ["●iCi", "?usju."], accepted
  end

  test "audits cross references Japanese fragments and multiword phrases" do
    accepted, rejected = @importer.send(
      :extract_candidates,
      "→きがん，ねがい，haimaa sakaZici，?utuui"
    )

    assert_equal ["?utuui"], accepted
    assert_equal %w[cross_reference_only non_okinawan_fragment multiword_fragment], rejected.map { |item| item[:status] }
  end

  test "normalises every accent alternative to an ASCII suffix" do
    assert_equal ["0", "1"], @importer.send(:split_accents, "⓪、①、⓪")
    assert_equal ["0*", "1*"], @importer.send(:split_accents, "⓪*、①*")

    expansions = @importer.send(
      :accent_expansions_for,
      "?ee",
      { "?ee" => ["1", "0"] }
    )

    assert_equal ["1", "0"], expansions.map { |item| item[:accent] }
    assert expansions.all? { |item| item[:match_status] == "matched_main" }
  end

  test "appends an accent class to the reading without circled annotation symbols" do
    reading = @importer.send(
      :build_reading,
      character: "藍",
      candidate: "?ee",
      accent: "1",
      row_number: 2,
      page: "1",
      japanese_headword: "あい",
      match_status: "matched_main"
    )

    assert_equal "?ee1", reading.value
    refute_match(/[⓪①]/, reading.value)
  end

  test "retains an index reading when accent data is missing" do
    expansions = @importer.send(:accent_expansions_for, "?eekuu", {})

    assert_equal [{ accent: nil, match_status: "index_only" }], expansions
  end

  test "uses the exact Japonic field and expected resource folder" do
    assert_equal "reading.japonic.okinawan_uchinaaguchi_shuri.ninjal",
                 Importers::OkinawanUchinaaguchiImporter::FIELD
    assert_equal Rails.root.join("resources", "沖繩語辞典", "okinawa_01.xlsx"),
                 Importers::OkinawanUchinaaguchiImporter::DEFAULT_MAIN_PATH
    assert_equal Rails.root.join("resources", "沖繩語辞典", "okinawa_02.xlsx"),
                 Importers::OkinawanUchinaaguchiImporter::DEFAULT_INDEX_PATH
  end
end
