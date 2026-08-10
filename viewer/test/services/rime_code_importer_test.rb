require_relative "../test_helper"
require "stringio"

class RimeCodeImporterTest < ActiveSupport::TestCase
  setup do
    CharacterInputCode.delete_all
  end

  test "imports single characters regardless of script and skips multi-character phrases" do
    io = StringIO.new(<<~YAML)
      # encoding: utf-8
      ---
      name: test
      version: "1"
      columns:
        - text
        - code
        - weight
      ...
      清\tegi\t100
      の\tno\t90
      한\than\t80
      清明\tegia\t50
    YAML

    result = CharacterData::RimeCodeImporter.new.import(
      system_id: "test_rime",
      source: "test",
      source_version: "abc123",
      io: io
    )

    assert_equal 3, result.codes
    assert_equal 1, result.skipped
    assert_equal 1, result.skipped_multi_character
    assert_equal 0, result.skipped_empty_code
    assert_equal 0, result.skipped_malformed
    assert_equal "multi_character", result.skip_samples.first.fetch(:reason)
    assert_match(/清明/, result.skip_samples.first.fetch(:line))
    row = CharacterInputCode.joins(:character_codepoint).find_by!(
      system_id: "test_rime",
      character_codepoints: { chr: "清" }
    )
    assert_equal "清", row.glyph
    assert_equal "egi", row.code
    assert_equal "100", row.metadata["weight"]
    assert CharacterInputCode.joins(:character_codepoint).exists?(
      system_id: "test_rime", code: "no", character_codepoints: { chr: "の" }
    )
    assert CharacterInputCode.joins(:character_codepoint).exists?(
      system_id: "test_rime", code: "han", character_codepoints: { chr: "한" }
    )
    refute CharacterInputCode.joins(:character_codepoint).exists?(
      system_id: "test_rime", character_codepoints: { chr: "清明" }
    )
  end

  test "imports Moran auxiliary code and keeps decomposition metadata" do
    io = StringIO.new("清\tqy\t氵青\n")

    CharacterData::RimeCodeImporter.new.import(
      system_id: "moran_test",
      source: "test",
      format: "moran_aux",
      io: io
    )

    row = CharacterInputCode.find_by!(system_id: "moran_test")
    assert_equal "qy", row.code
    assert_equal "auxiliary", row.kind
    assert_equal "氵青", row.metadata["decomposition"]
  end
  test "reports empty-code and malformed rows separately from intentional phrases" do
    io = StringIO.new(<<~YAML)
      ---
      name: test
      columns:
        - text
        - code
      ...
      清	q
      清明	qm
      明	
      broken
    YAML

    result = CharacterData::RimeCodeImporter.new.import(
      system_id: "test_rime_diagnostics",
      source: "test",
      io: io
    )

    assert_equal 1, result.codes
    assert_equal 3, result.skipped
    assert_equal 1, result.skipped_multi_character
    assert_equal 1, result.skipped_empty_code
    assert_equal 1, result.skipped_malformed
    assert_equal %w[multi_character empty_code malformed], result.skip_samples.map { |sample| sample.fetch(:reason) }
  end

end
