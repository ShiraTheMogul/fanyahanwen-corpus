# frozen_string_literal: true

# Run with:
#   bin/rails runner script/atlas_typed_hierarchy_smoke.rb

require "benchmark"

module AtlasTypedHierarchySmoke
  module_function

  def assert!(condition, message)
    raise "Atlas typed-hierarchy smoke failure: #{message}" unless condition
  end

  def run!
    periodisation = Atlas::Periodisation.default
    catalogue = Atlas::Catalogue.default

    periodisation.validate!
    catalogue.validate!

    assert!(catalogue.entries.all? { |entry| entry.kind == "polity" }, "entries/ contains a non-polity")
    assert!(catalogue.find("西周").nil?, "西周 is still exposed as a polity entry")

    western_zhou = catalogue.period("中國", "西周")
    eastern_zhou = catalogue.period("中國", "東周")
    assert!(western_zhou, "中國 / 西周 period is missing")
    assert!(eastern_zhou, "中國 / 東周 period group is missing")

    eastern_children = catalogue.periods_for("中國", parent_id: "東周").map { |row| row.fetch("id") }
    assert!((%w[春秋 戰國] - eastern_children).empty?, "東周 does not contain 春秋 and 戰國")

    zhou = catalogue.entries_for(macro_region_id: "中國", period_id: "西周")
    assert!(zhou.any? { |entry| entry.polity == "周" || entry.hanzi == "周" }, "西周 does not expose 周 as a polity")

    macro_ids = catalogue.macro_regions.map { |row| row.fetch("id") }
    assert!(macro_ids.none? { |id| id.include?("漢文") }, "Atlas macro-region labels still contain 漢文")
    corpus_roots = catalogue.macro_regions.flat_map { |row| Array(row["corpus_roots"]) }
    assert!(corpus_roots.any? { |root| root.include?("漢文") }, "corpus-root collection names lost 漢文")

    legacy_periods = periodisation.periods.select { |row| Array(row["legacy_entry_ids"]).any? }
    assert!(legacy_periods.any?, "no former period-as-polity IDs were preserved")
    sample = legacy_periods.first
    legacy_id = Array(sample["legacy_entry_ids"]).first
    redirect = catalogue.period_redirect_for_legacy_id(legacy_id)
    assert!(redirect, "legacy period ID #{legacy_id} has no redirect")
    assert!(redirect["macro_region_id"] == sample["macro_region"], "legacy redirect changed macro-region")
    assert!(redirect["period_id"] == sample["id"], "legacy redirect changed period")

    elapsed = Benchmark.realtime do
      1_000.times do
        catalogue.period("中國", "西周")
        catalogue.entries_for(macro_region_id: "中國", period_id: "西周")
      end
    end

    puts "Typed Atlas integration smoke passed."
    puts "Polities: #{catalogue.entries.length}; periods/subperiods: #{periodisation.periods.length}; macro-regions: #{macro_ids.length}."
    puts format("1,000 in-memory period/polity lookups: %.3fs", elapsed)
    true
  end
end

AtlasTypedHierarchySmoke.run!
