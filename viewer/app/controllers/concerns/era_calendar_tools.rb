# frozen_string_literal: true

# Adds the era-name calendar tester to the existing /tools/lunar endpoint so the
# historical-authority overlay does not need to replace config/routes.rb or the
# main ToolsController. Normal lunar-calendar requests continue through super.
module EraCalendarTools
  def lunar
    return super unless params[:calendar].to_s == "era"

    result = EraCalendarConverter.convert(
      direction: params[:direction],
      input: params[:input],
      country: params[:country],
      polity: params[:polity],
      period: params[:period]
    )

    render partial: "tools/era_calendar_output", locals: { result: result }
  rescue ArgumentError => e
    render partial: "tools/era_calendar_output",
           locals: { result: { "error" => e.message, "direction" => params[:direction].to_s } },
           status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.warn("[authority] era calendar converter failed: #{e.class}: #{e.message}")
    render partial: "tools/era_calendar_output",
           locals: { result: { "error" => "#{e.class}: #{e.message}", "direction" => params[:direction].to_s } },
           status: :unprocessable_entity
  end
end
