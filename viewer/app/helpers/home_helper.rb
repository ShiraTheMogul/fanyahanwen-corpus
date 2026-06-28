require "time"

module HomeHelper
  def corpus_activity_href(kind:, page: nil)
    query = { kind: kind }
    query[:page] = page if page.present?
    "/corpus/activity?#{query.to_query}"
  end

  def corpus_activity_time(value)
    time = Time.iso8601(value.to_s)
    content_tag(:time, I18n.l(time, format: I18n.t("common.time.corpus_activity_format")), datetime: time.iso8601)
  rescue ArgumentError, TypeError
    I18n.t("common.time.unknown")
  end

  def corpus_activity_context(item)
    [item["nation"], item["period"], item["region"]].map(&:presence).compact.uniq.join(" · ")
  end

  def corpus_activity_viewer_path(path)
    corpus_viewer_path(path.to_s.split("/"), format: nil)
  end
end
