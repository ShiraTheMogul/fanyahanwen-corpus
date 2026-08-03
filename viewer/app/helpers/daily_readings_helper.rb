# frozen_string_literal: true

# app/helpers/daily_readings_helper.rb
#
# Helper methods for the "今日誦詩" (Daily Shijing) widget.
#
# Key idea:
# - The database stores the poem metadata (Mao no, mother/period, subgroup, title, phase, and path).
# - We resolve the current corpus path through the stable Mao number, because compilation folders may move.
# - We read the *actual poem file* to display the full text.
# - The poem-of-the-day advances one item per day starting on lunar 正月初一.
#
module DailyReadingsHelper
  SHIJING_SERIES_KEY  = "shijing"
  MAX_LUNAR_BACKTRACK = 420

  # Returns a Hash for the widget, or nil if no reading can be found.
  #
  # Keys:
  #   :reading        => DailyReading (ActiveRecord model)
  #   :viewer_path    => relative path for corpus_viewer_path(...)
  #   :display_period => "國風期" etc (derived from reading.mother)
  #   :text           => full poem text (string)
  def daily_shijing_payload(date = Date.current)
    # Version 2 prevents an already-cached missing-file response surviving the fix.
    cache_key = "daily_reading:shijing:v2:#{date.iso8601}"

    Rails.cache.fetch(cache_key, expires_in: 36.hours) do
      reading = pick_daily_reading(SHIJING_SERIES_KEY, date: date)
      return nil if reading.nil?

      viewer_rel = DailyReadings::ShijingPathResolver.new.resolve(reading)

      mother = safe_attr(reading, :mother)
      display_period = mother.present? ? "#{mother}期" : nil

      {
        reading: reading,
        viewer_path: viewer_rel,
        display_period: display_period,
        text: read_poem_text_from_viewer_rel(viewer_rel)
      }
    end
  end

  private

  # Pattern you can reuse elsewhere:
  # - When you want a value *if it exists*, use respond_to? + public_send.
  #   For X in Y: if obj responds to method_name, call it, else nil.
  def safe_attr(obj, method_name)
    return nil unless obj.respond_to?(method_name)

    obj.public_send(method_name)
  end

  # Pick the reading for a given solar date.
  #
  # Rule:
  # - Find the solar date whose lunar date is 正月初一 (month 1 day 1, not leap).
  # - Compute offset days from that start.
  # - Pick (offset % total) in the ordered list.
  def pick_daily_reading(series_key, date:)
    scope = DailyReading.where(series_key: series_key, has_text: true).order(:order_index)
    total = scope.count
    return nil if total <= 0

    start = lunar_new_year_start(date)
    offset = (date - start).to_i

    scope.offset(offset % total).limit(1).first
  rescue StandardError => e
    Rails.logger.warn("[DailyReading] picker failed: #{e.class}: #{e.message}")
    nil
  end

  # Walk backwards from a solar date until we hit lunar month 1 day 1.
  # This avoids needing a lunar->solar conversion API.
  def lunar_new_year_start(date)
    d = date

    MAX_LUNAR_BACKTRACK.times do
      # You said you already have this solar->lunar converter in the app.
      l = LunarCalendar.at_lunar(d.year, d.month, d.day)

      month = l.respond_to?(:month) ? l.month.to_i : nil
      day   = l.respond_to?(:day) ? l.day.to_i : nil
      leap  = (l.respond_to?(:leap?) && l.leap?)

      return d if month == 1 && day == 1 && leap == false
      d -= 1
    end

    # Fallback if something goes wrong: Jan 1 is stable and at least deterministic.
    Date.new(date.year, 1, 1)
  rescue StandardError
    Date.new(date.year, 1, 1)
  end

  # Reads the poem text from the corpus file on disk.
  #
  # viewer_rel is a corpus-root-relative path such as:
  #   "中國漢文/clean/周朝/東周/戰國時代/周/詩經/國風/周南/關雎/關雎.txt"
  def read_poem_text_from_viewer_rel(viewer_rel)
    corpus_path = File.join(Rails.configuration.x.corpus_root.to_s, viewer_rel.to_s)
    raw = File.read(corpus_path, encoding: "utf-8", invalid: :replace, undef: :replace)

    # Remove metadata lines starting with '#'. Keep everything else.
    lines = raw.each_line.reject { |ln| ln.strip.start_with?("#") }

    # Trim only leading/trailing blank lines.
    lines.shift while lines.first&.strip&.empty?
    lines.pop while lines.last&.strip&.empty?

    lines.join
  rescue Errno::ENOENT
    "(missing poem file: #{viewer_rel})"
  rescue StandardError => e
    "(failed to read poem: #{e.class}: #{e.message})"
  end
end
