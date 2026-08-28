# frozen_string_literal: true

# Makes deterministic calendar parsing enter HistoricalDateResolver through the
# shared CalendarEngine before the legacy authority resolver runs. Reign eras,
# rulers, ranges, and authority ambiguity continue through super.
module CalendarEngineHistoricalDateResolver
  def resolve(metadata:)
    data = metadata.to_h.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }

    # Explicit materialized bounds remain the strongest metadata and are already
    # handled correctly by HistoricalDateResolver.
    explicit_start = data["year_start"] || data["year"]
    explicit_end = data["year_end"] || data["year"]
    return super if explicit_start.present? || explicit_end.present?

    text = [data["date_label"], data["date_text"]].map(&:to_s).reject(&:empty?).uniq.join(" ").strip
    return super if text.empty?

    calendar = CalendarEngine.call(operation: :resolve, value: text)
    return super unless calendar["resolved"] && calendar["kind"] == "date" && calendar["year"]

    year = Integer(calendar.fetch("year"))
    HistoricalDateResolver::Resolution.new(
      year_start: year,
      year_end: year,
      date_label: text,
      source: "calendar_engine:#{calendar['source_system']}",
      authority_kind: calendar["source_system"].to_s.in?(%w[gregorian iso8601 ce bce]) ? nil : "calendar_era",
      authority_id: calendar["source_system"],
      authority_name: calendar["source_label"],
      country: calendar["country"] || send(:context_country, data),
      confidence: calendar["confidence"] || "exact",
      candidates: Array(calendar["candidates"])
    )
  rescue ArgumentError, TypeError
    super
  end
end
