# frozen_string_literal: true

# Extends the existing /tools/lunar endpoint without adding a route. All
# deterministic calendar work goes through CalendarEngine. The established
# EraCalendarConverter remains responsible for authority-backed reign/regnal
# lookups when CalendarEngine has no deterministic interpretation.
module EraCalendarTools
  def lunar
    return super unless params[:calendar].to_s == "era"

    direction = params[:direction].to_s
    case direction
    when "absolute_year_to_systems", "civil_date_to_systems"
      result = CalendarEngine.call(operation: :represent, value: params[:input])
      result["direction"] = direction
      return render_calendar_engine_result(result)
    when "nomenclature_lookup"
      context = {}
      context["cycle_scope"] = params[:cycle_scope].to_s if params[:cycle_scope].present?
      result = CalendarEngine.call(operation: :lookup, value: params[:input], context: context)
      result["direction"] = direction
      return render_calendar_engine_result(result)
    when "calendar_convert"
      result = CalendarEngine.call(
        operation: :convert,
        value: params[:input],
        from: params[:from_calendar],
        to: params[:to_calendar]
      )
      result["direction"] = direction
      return render_calendar_engine_result(result)
    when "era_to_absolute"
      deterministic = CalendarEngine.call(operation: :resolve, value: params[:input])
      if deterministic["ambiguous"] || CalendarEngine::YEAR_SYSTEMS_BY_KEY.key?(deterministic["source_system"].to_s)
        deterministic["direction"] = "named_year_to_absolute"
        return render_calendar_engine_result(deterministic)
      end
    end

    result = CalendarEngine.call(
      operation: :era_convert,
      value: params[:input],
      direction: params[:direction],
      country: params[:country],
      polity: params[:polity],
      period: params[:period]
    )
    render partial: "tools/era_calendar_output", locals: { result: result }
  rescue ArgumentError => e
    render partial: "tools/calendar_engine_output",
           locals: { result: { "resolved" => false, "error" => e.message, "direction" => params[:direction].to_s } },
           status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.warn("[calendar] calculator failed: #{e.class}: #{e.message}")
    render partial: "tools/calendar_engine_output",
           locals: { result: { "resolved" => false, "error" => "#{e.class}: #{e.message}", "direction" => params[:direction].to_s } },
           status: :unprocessable_entity
  end

  private

  def render_calendar_engine_result(result)
    status = result["resolved"] || result["ambiguous"] ? :ok : :unprocessable_entity
    render partial: "tools/calendar_engine_output", locals: { result: result }, status: status
  end
end
