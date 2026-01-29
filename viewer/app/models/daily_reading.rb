# frozen_string_literal: true

# app/models/daily_reading.rb
#
# Generic daily reading row.
#
# This is intentionally minimal so it can be reused for other series later
# (e.g. 全唐詩). The importer is responsible for providing:
# - series_key: identifies the series ("shijing", "quantangshi", ...)
# - order_index: the sequence number within that series
# - path: corpus-relative path segment used by CorpusViewer
# - has_text: false for placeholder items (e.g. 笙詩)
#
class DailyReading < ApplicationRecord
  validates :series_key, presence: true
  validates :mother, presence: true
  validates :title, presence: true
  validates :order_index, presence: true
  validates :path, presence: true

  # subgroup can be nil for series that have no subcategory folder.
end
