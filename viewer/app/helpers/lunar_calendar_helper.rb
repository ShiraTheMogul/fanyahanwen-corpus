# app/helpers/lunar_calendar_helper.rb
module LunarCalendarHelper
  def lunar_today_string
    d = Date.current
    l = LunarCalendar.at_lunar(d.year, d.month, d.day)

    era  = l.respond_to?(:chinese_era) ? "#{l.chinese_era}年 " : ""
    leap = (l.respond_to?(:leap?) && l.leap?) ? "閏" : ""

    month = "#{Zhengshu.format(l.month, use_you: true)}月"
    day   = "#{Zhengshu.format(l.day, use_you: true)}日"

    "#{era}#{leap}#{month}#{day}"
  rescue => e
    Rails.logger.warn("LunarCalendar failed: #{e.class}: #{e.message}")
    nil
  end
end
