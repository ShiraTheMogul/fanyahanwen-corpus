require_relative "../../test_helper"

class XiaoxuetangImporterTest < ActiveSupport::TestCase
  setup do
    @importer = Importers::XiaoxuetangImporter.new(
      zip_path: Rails.root.join("tmp", "unused-xiaoxuetang.zip"),
      audit_dir: Rails.root.join("tmp", "xiaoxuetang-test-audit"),
      verbose: false
    )
    @dataset = Importers::XiaoxuetangImporter::Dataset.new(
      family: "wu",
      dataset_id: "120",
      dataset_key: "120",
      title: "吳語_上海",
      variety_label: "上海",
      variety_label_en: "Shanghai",
      workbook_name: "120 吳語_上海.xlsx",
      archive_name: "ccr06_wuyu_data_xlsx.zip",
      field: "reading.wu.xiaoxuetang_120.ipa",
      ruby_key: "xiaoxuetang_120",
      metadata_warnings: []
    )
  end

  test "imports a complete segmental reading even when tone is missing" do
    reading = resolve(
      row(character: "東", initial: "t", final: "uŋ")
    ).first

    assert_equal "tuŋ", reading.value
    assert_includes reading.partial_reasons, "missing_tone"
  end

  test "inherits an unambiguous ditto-style initial and tone" do
    readings = resolve(
      row(row_number: 2, character: "東", initial: "t", final: "ɔŋ", tone_value: "55", tone_class: "陰平"),
      row(row_number: 3, character: "東", initial: nil, final: "aŋ", tone_value: nil)
    )

    assert_equal ["tɔŋ⁵⁵", "taŋ⁵⁵"], readings.map(&:value)
    assert_includes readings.last.resolution_notes, "inherited_initial"
    assert_includes readings.last.resolution_notes, "inherited_tone"
  end

  test "keeps an ambiguous incomplete reading instead of rejecting it" do
    readings = resolve(
      row(row_number: 2, character: "吳", initial: "v", final: "Y", tone_value: "113"),
      row(row_number: 3, character: "吳", initial: "ɦ", final: "u", tone_value: nil),
      row(row_number: 4, character: "吳", initial: nil, final: "ɲ̀", tone_value: nil)
    )

    assert_equal "…ɲ̀¹¹³", readings.last.value
    assert_includes readings.last.partial_reasons, "ambiguous_initial"
  end

  test "uses tone class when numeric tone is absent" do
    reading = resolve(
      row(character: "凍", initial: "tɕ", final: "yuŋ", tone_class: "平")
    ).first

    assert_equal "tɕyuŋ〔平〕", reading.value
    assert_includes reading.partial_reasons, "tone_class_without_tone_value"
  end

  test "treats source placeholder dashes as missing data" do
    assert_empty resolve(
      row(
        character: "掐",
        initial: "--",
        final: "--",
        tone_class: "--",
        note: "--"
      )
    )
  end

  test "does not create a dictionary reading from a completely empty row" do
    assert_empty resolve(row(character: "東"))
  end

  test "repairs a strongly typed shifted zero-initial row" do
    source_row = row(
      character: "又",
      initial: "iəu",
      final: "去",
      tone_value: nil,
      tone_class: "45",
      note: "0"
    )

    repaired = @importer.send(:repair_shifted_row, source_row)
    reading = resolve(repaired).first

    assert_equal "0", repaired.initial
    assert_equal "iəu", repaired.final
    assert_equal "45", repaired.tone_value
    assert_equal "去", repaired.tone_class
    assert_equal "iəu⁴⁵", reading.value
  end

  test "repairs a strongly typed right-shifted segment and tone" do
    source_row = row(
      character: "該",
      initial: nil,
      final: "k",
      tone_value: nil,
      tone_class: "ai",
      note: "33"
    )

    repaired = @importer.send(:repair_shifted_row, source_row)
    reading = resolve(repaired).first

    assert_equal "k", repaired.initial
    assert_equal "ai", repaired.final
    assert_equal "33", repaired.tone_value
    assert_nil repaired.tone_class
    assert_equal "kai³³", reading.value
  end

  test "repairs shifted tone columns without inventing a missing final" do
    source_row = row(
      character: "傾",
      initial: "kʰ",
      final: "平",
      tone_value: nil,
      tone_class: "11"
    )

    repaired = @importer.send(:repair_shifted_row, source_row)
    reading = resolve(repaired).first

    assert_nil repaired.final
    assert_equal "11", repaired.tone_value
    assert_equal "平", repaired.tone_class
    assert_equal "kʰ…¹¹", reading.value
    assert_includes reading.partial_reasons, "missing_final"
  end

  test "decodes a CP437-rendered Big5 workbook filename" do
    decoded = @importer.decode_entry_name("120 ºd╗y_ñW«ⁿ.xlsx")

    assert_equal "120 吳語_上海.xlsx", decoded
  end

  test "decodes CP437-rendered text even when rubyzip tags it ASCII-8BIT" do
    mojibake = "120 ºd╗y_ñW«ⁿ.xlsx".b

    assert_equal "120 吳語_上海.xlsx", @importer.decode_entry_name(mojibake)
  end

  test "decodes raw Big5 filename bytes" do
    raw = ["31323020a764bb795fa457aefc2e786c7378"].pack("H*")

    assert_equal "120 吳語_上海.xlsx", @importer.decode_entry_name(raw)
  end

  test "preserves an already-correct UTF-8 workbook filename" do
    assert_equal "120 吳語_上海.xlsx", @importer.decode_entry_name("120 吳語_上海.xlsx")
  end

  test "extracts the locality label and Mandarin romanisation from the workbook filename" do
    dataset = @importer.send(
      :dataset_from_filename,
      "120 吳語_上海.xlsx",
      "wu",
      "ccr06_wuyu_data_xlsx.zip"
    )

    assert_equal "上海", dataset.variety_label
    assert_equal "Shanghai", dataset.variety_label_en
    assert_equal "reading.wu.xiaoxuetang_120.ipa", dataset.field
  end

  test "preserves a hand-corrected English locality label when registry metadata is resynced" do
    old_entry = {
      "variety_label_en" => "Corrected English label",
      "ruby" => { "label_en" => "Corrected English label — IPA" }
    }
    generated_entry = @importer.send(:registry_entry, @dataset)

    merged = @importer.send(:merge_registry_entry, old_entry, generated_entry)

    assert_equal "Corrected English label", merged["variety_label_en"]
    assert_equal "Corrected English label — IPA", merged.dig("ruby", "label_en")
    assert_equal "上海", merged["variety_label"]
  end

  private

  def resolve(*rows)
    @importer.resolve_group(rows, dataset: @dataset)
  end

  def row(
    row_number: 2,
    char_number: "1",
    character:,
    initial: nil,
    final: nil,
    tone_value: nil,
    tone_class: nil,
    note: nil
  )
    Importers::XiaoxuetangImporter::SourceRow.new(
      row_number: row_number,
      char_number: char_number,
      character: character,
      initial: initial,
      final: final,
      tone_value: tone_value,
      tone_class: tone_class,
      note: note
    )
  end
end
