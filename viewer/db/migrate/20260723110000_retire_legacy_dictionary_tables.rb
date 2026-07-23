# frozen_string_literal: true

class RetireLegacyDictionaryTables < ActiveRecord::Migration[8.1]
  REQUIRED_WORKS = {
    127_355 => { title: "御定康熙字典", sections: 214, minimum_entries: 46_000 },
    79_653 => { title: "說文解字", sections: 540, minimum_entries: 9_800 },
    127_386 => { title: "廣韻", minimum_sections: 1, minimum_entries: 25_000 }
  }.freeze

  LEGACY_TABLES = %i[
    character_component_memberships
    shuowen_components
    character_radical_memberships
    kangxi_radicals
  ].freeze

  def up
    verify_normalized_dictionary_catalogue!
    verify_kangxi_radical_source!

    LEGACY_TABLES.each do |table_name|
      next unless table_exists?(table_name)

      say_with_time("Dropping retired table #{table_name}") do
        drop_table table_name
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "The retired dictionary tables were duplicate derived data. Rebuild the normalized dictionaries from their reviewed source plans instead."
  end

  private

  def verify_normalized_dictionary_catalogue!
    raise "dictionary_works does not exist" unless table_exists?(:dictionary_works)
    raise "dictionary_sections does not exist" unless table_exists?(:dictionary_sections)
    raise "dictionary_entries does not exist" unless table_exists?(:dictionary_entries)

    REQUIRED_WORKS.each do |corpus_work_id, requirements|
      work = select_one(<<~SQL.squish)
        SELECT id, title, section_count, entry_count
        FROM dictionary_works
        WHERE corpus_work_id = #{connection.quote(corpus_work_id)}
        LIMIT 1
      SQL

      raise "Normalized dictionary #{corpus_work_id} is missing" unless work

      actual_sections = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM dictionary_sections
        WHERE dictionary_work_id = #{connection.quote(work.fetch("id"))}
      SQL
      actual_entries = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM dictionary_entries
        WHERE dictionary_work_id = #{connection.quote(work.fetch("id"))}
      SQL

      if requirements[:sections] && actual_sections != requirements.fetch(:sections)
        raise "#{requirements[:title]} section parity failed: #{actual_sections} != #{requirements[:sections]}"
      end
      if requirements[:minimum_sections] && actual_sections < requirements.fetch(:minimum_sections)
        raise "#{requirements[:title]} has no usable normalized sections"
      end
      if actual_entries < requirements.fetch(:minimum_entries)
        raise "#{requirements[:title]} entry parity failed: #{actual_entries} < #{requirements[:minimum_entries]}"
      end
      if work.fetch("section_count").to_i != actual_sections || work.fetch("entry_count").to_i != actual_entries
        raise "#{requirements[:title]} stored counts do not match its normalized rows"
      end
    end
  end

  def verify_kangxi_radical_source!
    raise "character_properties does not exist" unless table_exists?(:character_properties)

    count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM character_properties
      WHERE field = 'kRSUnicode'
        AND value IS NOT NULL
        AND TRIM(value) <> ''
    SQL

    raise "No kRSUnicode source rows remain; radical membership cannot be derived" if count.zero?

    work_id = select_value(<<~SQL.squish)
      SELECT id
      FROM dictionary_works
      WHERE corpus_work_id = 127355
      LIMIT 1
    SQL
    metadata_rows = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM dictionary_sections
      WHERE dictionary_work_id = #{connection.quote(work_id)}
        AND metadata IS NOT NULL
        AND TRIM(CAST(metadata AS TEXT)) NOT IN ('', '{}')
    SQL

    raise "Normalized Kangxi sections do not contain radical metadata" unless metadata_rows == 214
  end
end
