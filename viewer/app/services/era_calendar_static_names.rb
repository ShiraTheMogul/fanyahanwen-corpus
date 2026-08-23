# frozen_string_literal: true

# Keep the era converter's curated ruler-name deduplication on the same bounded
# file-backed registry used by HistoricalDateResolver. No interactive calendar
# path should instantiate the broad VariantMapping graph.
module EraCalendarStaticNames
  private

  def compact_equivalent_names(names)
    expander = AuthorityNameExpander.new(registry: AuthorityHanVariantRegistry.instance)
    kept = []
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).each do |name|
      next if kept.any? do |existing|
        existing == name || expander.expand(existing).any? { |form| form.name == name }
      end

      kept << name
    end
    kept
  rescue StandardError
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).uniq
  end
end
