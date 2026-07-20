# frozen_string_literal: true

module AtlasQualityVerifier
  module_function

  def verify!(catalogue: Atlas::Catalogue.default)
    forbidden_regions = %w[西域]
    forbidden_roots = %w[他漢文 西域漢文]

    leaked_regions = catalogue.macro_regions.filter_map do |row|
      row.fetch("id").to_s if forbidden_regions.include?(row.fetch("id").to_s)
    end
    raise "Forbidden Atlas macro-regions: #{leaked_regions.join(', ')}" if leaked_regions.any?

    leaked_roots = catalogue.macro_regions.flat_map { |row| Array(row["corpus_roots"]).map(&:to_s) } & forbidden_roots
    raise "Excluded corpus roots leaked into Atlas navigation: #{leaked_roots.join(', ')}" if leaked_roots.any?

    catalogue.macro_regions.each do |region|
      verify_period_rows!(catalogue, region.fetch("id"), region.fetch("periods", []))
    end

    catalogue.entries.each do |entry|
      bad_authors = entry.represented_authors.filter_map do |row|
        row["name"].to_s if row["name"].to_s.match?(/[;；]/)
      end
      if bad_authors.any?
        raise "Unsplit author values for #{entry.id}: #{bad_authors.join(' | ')}"
      end
    end

    puts "Atlas quality verification passed."
    true
  end

  def verify_period_rows!(catalogue, region_id, rows)
    Array(rows).each do |row|
      entries = catalogue.entries_for(macro_region_id: region_id, period_id: row.fetch("id"))
      expected = entries.sort_by { |entry| [-entry.work_count, entry.title] }.map(&:id)
      actual = entries.map(&:id)
      unless actual == expected
        raise "Atlas period ordering is wrong for #{region_id} / #{row['id']}"
      end

      verify_period_rows!(catalogue, region_id, row["children"])
    end
  end
end

AtlasQualityVerifier.verify! if $PROGRAM_NAME == __FILE__
