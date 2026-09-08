# frozen_string_literal: true

# CalendarEngine's ordinary full-date parser required at least four year
# digits. Historical dates such as 618-06-18 are valid inputs too. Handle that
# short-year form here and delegate every other expression to the existing
# engine, keeping all of its BCE/CE and written-date behaviour in one place.
module CalendarEngineReliability
  private

  def resolve_absolute_date(raw)
    if (match = raw.match(/\A([+-]?\d{1,3})-(\d{2})-(\d{2})(?:T.*)?\z/))
      year = Integer(match[1], 10)
      month = Integer(match[2], 10)
      day = Integer(match[3], 10)
      raise ArgumentError, "There is no historical year zero." if year.zero?
      return nil unless valid_calendar_fields?(year, month, day, frame: "gregorian")

      return absolute_result(raw, year, month, day, "iso8601")
    end

    super
  end
end
