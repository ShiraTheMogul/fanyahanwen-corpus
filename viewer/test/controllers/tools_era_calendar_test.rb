# frozen_string_literal: true

require "test_helper"

class ToolsEraCalendarTest < ActionDispatch::IntegrationTest
  test "tools page renders era calendar as an ordinary tools-picker panel source" do
    get tools_path

    assert_response :success
    assert_select "form[action='#{tools_lunar_path}'] input[name='calendar'][value='era']", 1
    assert_select "turbo-frame#era_calendar_out", 1
  end

  test "era calendar response targets its own turbo frame" do
    post tools_lunar_path, params: {
      calendar: "era",
      direction: "absolute_to_era",
      input: "1853",
      country: "China"
    }

    assert_response :success
    assert_select "turbo-frame#era_calendar_out", 1
  end
end
