# frozen_string_literal: true

periodisation = Atlas::Periodisation.default
catalogue = Atlas::Catalogue.default

raise "他漢文 is not excluded" unless periodisation.excluded_corpus_root?("他漢文")
raise "他漢文 leaked into macro-region roots" if catalogue.macro_regions.any? { |row| Array(row["corpus_roots"]).include?("他漢文") }
raise "United Kingdom leaked into Atlas macro-regions" if catalogue.macro_regions.any? { |row| row["id"].to_s == "英國" }

japan = catalogue.macro_region!("日本")
root_ids = Array(japan["periods"]).map { |row| row["id"] }
expected = ["倭", "日本", "大日本帝國"]
raise "Unexpected Japan roots: #{root_ids.inspect}" unless root_ids == expected

japan_group = Array(japan["periods"]).find { |row| row["id"] == "日本" }
child_ids = Array(japan_group["children"]).map { |row| row["id"] }
expected_children = [
  "奈良時代", "平安時代", "鎌倉時代", "室町時代", "安土桃山時代",
  "江戶時代", "明治時代", "大正時代", "昭和時代", "平成時代", "令和時代"
]
raise "Unexpected Japan child periods: #{child_ids.inspect}" unless child_ids == expected_children

puts "Atlas region-policy smoke test passed."
puts "Macro-regions: #{catalogue.macro_regions.length}"
puts "Japan roots: #{root_ids.join(' · ')}"
puts "Japan child periods: #{child_ids.length}"
