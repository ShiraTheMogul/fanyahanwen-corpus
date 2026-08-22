# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class SupplementaryAuthorityIndexTest < ActiveSupport::TestCase
  test "builds Shang and Xia authority records with explicit and derived Han aliases" do
    Dir.mktmpdir do |directory|
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      source = Rails.root.join("data", "shang_people.xlsx")

      result = SupplementaryAuthorityIndex.build_if_needed!(
        source_path: source,
        cache_store: cache_store,
        logger: nil
      )

      assert result.available?
      assert result.rebuilt?
      assert SupplementaryAuthorityIndex.current?(cache_store: cache_store)
      assert_operator result.counts.fetch("people"), :>, 200
      assert_operator result.counts.fetch("shang_diviners"), :>, 80
      assert_operator result.counts.fetch("derived_names"), :>, 0

      db = SQLite3::Database.new(result.path, readonly: true)
      application_tables = db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      ).flatten
      assert_equal %w[metadata names people], application_tables

      # The workbook pre-numbers future empty rows. They are editing space, not
      # authority records, and must not be imported merely because person_id is
      # already present.
      assert_equal 0, db.get_first_value(
        "SELECT COUNT(*) FROM people WHERE source_sheet = 'Shang' AND person_id = '204'"
      )
      assert_equal 0, db.get_first_value(
        "SELECT COUNT(*) FROM people WHERE source_sheet = 'Xia' AND person_id = '44'"
      )

      li = db.get_first_row(
        "SELECT source_sheet, person_id, primary_name, name_han FROM people WHERE source_sheet = 'Shang' AND name_han = '歷'"
      )
      assert_equal ["Shang", "127", "Li", "歷"], li

      explicit_variant = db.get_first_row(
        "SELECT explicit_name, derivation FROM names WHERE source_sheet = 'Shang' AND name_chn = '齐' LIMIT 1"
      )
      assert_equal [1, "explicit_alias"], explicit_variant

      opencc_alias = db.get_first_row(<<~SQL)
        SELECT n.name_chn, n.explicit_name, n.derivation
        FROM names n
        JOIN people p ON p.source_sheet = n.source_sheet AND p.person_id = n.person_id
        WHERE p.name_han = '巫賢' AND n.name_chn = '巫贤'
        LIMIT 1
      SQL
      assert_equal "巫贤", opencc_alias[0]
      assert_equal 0, opencc_alias[1]
      assert_includes opencc_alias[2], "opencc_simplified_traditional"
    ensure
      db&.close
    end
  end
end
