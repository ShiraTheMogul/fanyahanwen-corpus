# frozen_string_literal: true

require "benchmark"

catalogue = Atlas::Catalogue.default
store = Atlas::EntryStore.default

puts "[atlas] verifying compiled catalogue"
catalogue.validate!
store.validate!

lookups = store.all.first(100)
lookup_time = Benchmark.realtime do
  100.times do
    lookups.each { |entry| raise "lookup failed: #{entry.id}" unless store.find(entry.id) }
  end
end

browse_time = Benchmark.realtime do
  100.times do
    catalogue.macro_regions.each do |region|
      catalogue.periods_for(region.fetch("id")).each do |period|
        catalogue.entries_for(macro_region_id: region.fetch("id"), period_id: period.fetch("id"))
      end
    end
  end
end

published = store.all.count { |entry| store.article_exists?(entry) }
puts "[atlas] entries: #{store.all.length}; published source articles: #{published}"
puts format("[atlas] 10,000 indexed lookups: %.3fs", lookup_time)
puts format("[atlas] 100 complete region/period traversals: %.3fs", browse_time)

raise "Atlas indexed lookup is unexpectedly slow" if lookup_time > 1.0
raise "Atlas region/period traversal is unexpectedly slow" if browse_time > 2.0

puts "[atlas] smoke test passed"
