# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "pathname"
require "time"

# Applies only the already-audited chronology rows that do not need another
# corpus/text scan.  The completed dates.tsv is treated as a checkpoint:
#
#   * date_label  -> exact date from existing metadata-level evidence
#   * polity_ca   -> broad ca already derived from the curated period/polity
#   * author_ca   -> ca only when the author's range overlaps the folder period
#   * self_regnal -> always deferred for the stricter self-reference pass
#
# Existing chronology is never overwritten.  Every candidate row is also
# checked against the current metadata so a stale report cannot silently write
# into a work that changed after the long audit.
class CorpusMetadataDateCheckpointApplier
  EXACT_DATE_KEYS = %w[date year year_start year_end].freeze
  ELIGIBLE_ACTIONS = %w[date_label polity_ca author_ca].freeze
  DEFERRED_ACTIONS = %w[self_regnal].freeze
  REQUIRED_HEADERS = %w[path action title period polity date ca evidence_start evidence_end].freeze
  WRITE_RETRIES = 12
  WRITE_RETRY_SLEEP = 0.25

  Result = Data.define(
    :rows,
    :eligible,
    :written,
    :would_write,
    :already_chronologized,
    :deferred_self_regnal,
    :author_path_rejected,
    :author_path_unknown,
    :folder_overrides,
    :folder_conflicts,
    :period_repairs,
    :polity_repairs,
    :folder_repair_unknown,
    :stale,
    :missing,
    :errors,
    :report_dir
  )

  def initialize(
    root:,
    report_path:,
    apply: false,
    logger: Rails.logger,
    progress_every: 5_000,
    path_filter: nil,
    report_root: nil
  )
    @root = Pathname(root).realpath
    @report_path = Pathname(report_path).realpath
    @apply = apply
    @logger = logger
    @progress_every = [Integer(progress_every), 1].max
    @path_filter = path_filter.to_s.strip
    @path_filter = nil if @path_filter.empty?
    @report_root = Pathname(report_root || Rails.root.join("tmp", "corpus_metadata_auto_dates"))
    @review_rows = []
  end

  def run!
    counters = Hash.new(0)
    headers = nil

    CSV.foreach(@report_path, headers: true, col_sep: "\t", encoding: "bom|utf-8").with_index(1) do |row, index|
      headers ||= Array(row.headers).map(&:to_s)
      validate_headers!(headers) if index == 1

      counters["rows"] += 1
      process_row!(row.to_h, counters)
      print_progress(index, counters) if (index % @progress_every).zero?
    end

    report_dir = write_review_report!(counters)
    Result.new(
      rows: counters["rows"],
      eligible: counters["eligible"],
      written: counters["written"],
      would_write: counters["would_write"],
      already_chronologized: counters["already_chronologized"],
      deferred_self_regnal: counters["deferred_self_regnal"],
      author_path_rejected: counters["author_path_rejected"],
      author_path_unknown: counters["author_path_unknown"],
      folder_overrides: counters["folder_overrides"],
      folder_conflicts: counters["folder_conflicts"],
      period_repairs: counters["period_repairs"],
      polity_repairs: counters["polity_repairs"],
      folder_repair_unknown: counters["folder_repair_unknown"],
      stale: counters["stale"],
      missing: counters["missing"],
      errors: counters["errors"],
      report_dir: report_dir
    )
  end

  private

  def process_row!(row, counters)
    action = row["action"].to_s
    path_text = row["path"].to_s.tr("\\", "/")
    return unless path_selected?(path_text)

    if DEFERRED_ACTIONS.include?(action)
      counters["deferred_self_regnal"] += 1
      review(row, "deferred_self_regnal")
      return
    end
    return unless ELIGIBLE_ACTIONS.include?(action)

    counters["eligible"] += 1
    metadata_path = safe_metadata_path(path_text)
    unless metadata_path&.file?
      counters["missing"] += 1
      review(row, "missing_metadata")
      return
    end

    metadata = read_metadata(metadata_path)
    unless report_matches_current_metadata?(row, metadata, path_text)
      counters["stale"] += 1
      review(row, "stale_report")
      return
    end

    path_context = path_chronology_context(path_text) if %w[author_ca polity_ca].include?(action)
    folder_conflict = checkpoint_folder_conflict?(row, path_context)
    folder_targets = folder_conflict ? folder_metadata_targets(path_text, path_context) : {}
    folder_repairs = folder_conflict ? folder_metadata_repairs(path_text, metadata, path_context) : {}
    counters["folder_repair_unknown"] += 1 if folder_conflict && folder_targets.empty?

    if action == "author_ca"
      unless path_context
        counters["author_path_unknown"] += 1
        review(row, "author_path_unknown")
        return
      end

      author_range = row_year_range(row)
      unless author_range && ranges_overlap?(*author_range, path_context[:start], path_context[:end])
        counters["author_path_rejected"] += 1
        review(
          row,
          "author_path_rejected",
          path_period: path_context[:label],
          path_start: path_context[:start],
          path_end: path_context[:end]
        )
        return
      end
    end

    key, value = chronology_value(row)
    if action == "polity_ca" && key == "ca"
      original = row["ca"].to_s.strip
      if !original.empty? && value != original
        counters["folder_overrides"] += 1
        if folder_conflict
          counters["folder_conflicts"] += 1
          repair_extra = folder_repair_review_fields(folder_repairs)
          review(
            row,
            "folder_overrode_conflicting_metadata_ca",
            {
              folder_ca: value,
              path_period: path_context[:label],
              path_start: path_context[:start],
              path_end: path_context[:end]
            }.merge(repair_extra)
          )
        end
      end
    end

    unless key && value
      counters["errors"] += 1
      review(row, "invalid_checkpoint_value")
      return
    end

    # A previous interrupted checkpoint may already have written ca while still
    # carrying the bad Wikisource-category period/polity.  If the stored ca is
    # exactly the safe folder-derived value, finish that metadata repair without
    # disturbing any independently supplied exact chronology.
    if chronology_present?(metadata)
      if folder_conflict && present_value?(metadata["ca"]) && metadata["ca"].to_s == value.to_s
        changed = apply_folder_repairs!(metadata, folder_repairs, counters)
        if changed && @apply
          write_metadata(metadata_path, metadata)
          counters["written"] += 1
        elsif changed
          counters["would_write"] += 1
        end
      end
      counters["already_chronologized"] += 1
      return
    end

    metadata[key] = value
    apply_folder_repairs!(metadata, folder_repairs, counters) if folder_conflict

    if @apply
      write_metadata(metadata_path, metadata)
      counters["written"] += 1
    else
      counters["would_write"] += 1
    end
  rescue StandardError => e
    counters["errors"] += 1
    @logger&.warn("[corpus_metadata_dates checkpoint] #{path_text}: #{e.class}: #{e.message}")
    review(row, "error", error: "#{e.class}: #{e.message}")
  end

  def validate_headers!(headers)
    missing = REQUIRED_HEADERS - headers
    return if missing.empty?

    raise ArgumentError, "checkpoint report is missing columns: #{missing.join(', ')}"
  end

  def path_selected?(path_text)
    @path_filter.nil? || path_text.include?(@path_filter)
  end

  def safe_metadata_path(path_text)
    relative = Pathname(path_text)
    return nil if relative.absolute? || relative.each_filename.any? { |piece| piece == ".." }
    return nil unless relative.basename.to_s == "metadata.json"

    candidate = @root.join(relative).cleanpath
    candidate.relative_path_from(@root)
    candidate
  rescue ArgumentError
    nil
  end

  def read_metadata(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise Encoding::InvalidByteSequenceError, "invalid UTF-8" unless raw.valid_encoding?

    JSON.parse(raw.sub(/\A\uFEFF/, ""))
  end

  def report_matches_current_metadata?(row, metadata, path_text)
    return false unless metadata["title"].to_s == row["title"].to_s

    ordinary_match = %w[period polity].all? { |key| metadata[key].to_s == row[key].to_s }
    return true if ordinary_match
    return false unless row["action"].to_s == "polity_ca"

    path_context = path_chronology_context(path_text)
    return false unless checkpoint_folder_conflict?(row, path_context)

    targets = folder_metadata_targets(path_text, path_context)
    return false if targets.empty?

    %w[period polity].all? do |key|
      current = metadata[key].to_s
      old = row[key].to_s
      target = targets[key].to_s
      current == old || (!target.empty? && current == target)
    end
  end

  def checkpoint_folder_conflict?(row, path_context)
    return false unless row["action"].to_s == "polity_ca"

    report_range = row_year_range(row)
    report_range && path_context && !ranges_overlap?(*report_range, path_context[:start], path_context[:end])
  end

  def folder_metadata_repairs(path_text, metadata, path_context)
    targets = folder_metadata_targets(path_text, path_context)
    return {} if targets.empty?

    %w[period polity].each_with_object({}) do |key, output|
      target = targets[key].to_s.strip
      next if target.empty?

      current = metadata[key].to_s.strip
      next if current == target

      output[key] = { before: current, after: target }
    end
  end

  def folder_metadata_targets(path_text, path_context)
    return {} unless path_context

    parts = path_text.split("/")
    clean_index = parts.index("clean")
    return {} unless clean_index

    folders = Array(parts[(clean_index + 1)...-2])
    return {} if folders.empty?

    recognized = recognized_path_periods(folders)
    return {} if recognized.empty?

    period_entry = recognized.last
    # 大清 / 大明 / 大元 are polity folders.  Their normalized form resolves to
    # the same dynasty range as the parent, but the corpus convention keeps the
    # parent as period and the 大... folder as polity.
    if period_entry[:label].start_with?("大") && recognized.length >= 2
      previous = recognized[-2]
      if same_normalized_polity?(period_entry[:label], previous[:label])
        period_entry = previous
      end
    end

    period = period_entry[:label]
    polity = folder_polity_for(folders, recognized, period_entry)
    { "period" => period, "polity" => polity }.compact
  end

  def recognized_path_periods(folders)
    context = nil
    output = []

    folders.each_with_index do |value, index|
      range = period_range_for_value(value)
      next unless range

      if context
        start_year = [context[:start], range[0]].max
        end_year = [context[:end], range[1]].min
        # Ignore a homonymous later dynasty embedded in an ancient polity path.
        next if start_year > end_year
        context = { start: start_year, end: end_year }
      else
        context = { start: range[0], end: range[1] }
      end

      output << { index: index, label: value, start: context[:start], end: context[:end] }
    end

    output
  end

  def folder_polity_for(folders, recognized, period_entry)
    period = period_entry[:label]

    subtype_polities = {
      "北宋" => "宋", "南宋" => "宋",
      "西漢" => "漢", "東漢" => "漢",
      "西晋" => "晉", "西晉" => "晉", "東晋" => "晉", "東晉" => "晉"
    }
    return subtype_polities[period] if subtype_polities.key?(period)

    child = folders[period_entry[:index] + 1]
    if child&.start_with?("大") && same_normalized_polity?(child, period)
      return child
    end

    # These folders are deliberately broad periods whose next directory is the
    # corpus's polity/community division (曹魏, 劉宋, 魏, 宋, etc.).
    child_polity_periods = %w[三國 三国 南北朝 春秋 春秋時代 春秋时代 戰國 战国 戰國時代 战国时代]
    return child if child && child_polity_periods.include?(period)

    if period.end_with?("朝")
      stripped = period.sub(/朝\z/, "")
      return stripped unless stripped.empty?
    end

    # If a prior recognized parent is a dynasty, use its polity form for a
    # recognized subperiod such as 南宋/東漢 handled above or future equivalents.
    previous = recognized.reverse.find { |entry| entry[:index] < period_entry[:index] && entry[:label].end_with?("朝") }
    return previous[:label].sub(/朝\z/, "") if previous

    nil
  end

  def same_normalized_polity?(left, right)
    (normalized_polity_forms(left) & normalized_polity_forms(right)).any?
  end

  def apply_folder_repairs!(metadata, repairs, counters)
    return false if repairs.empty?

    changed = false
    repairs.each do |key, change|
      metadata[key] = change.fetch(:after)
      counters["#{key}_repairs"] += 1
      changed = true
    end
    changed
  end

  def folder_repair_review_fields(repairs)
    output = {}
    %w[period polity].each do |key|
      change = repairs[key]
      next unless change

      output["#{key}_before".to_sym] = change[:before]
      output["#{key}_after".to_sym] = change[:after]
    end
    output[:folder_repair_unknown] = true if repairs.empty?
    output
  end

  def chronology_present?(metadata)
    EXACT_DATE_KEYS.any? { |key| present_value?(metadata[key]) } || present_value?(metadata["ca"])
  end

  def chronology_value(row)
    case row["action"].to_s
    when "date_label"
      value = row["date"].to_s.strip
      return ["date", value] unless value.empty?
    when "polity_ca"
      # Folder chronology is the curated corpus placement.  It can be more
      # specific than the metadata-derived value in the old checkpoint and can
      # also correct category residue which pointed at the wrong dynasty.
      if (path_context = path_chronology_context(row["path"].to_s))
        return ["ca", format_circa(path_context[:start], path_context[:end])]
      end

      value = row["ca"].to_s.strip
      return ["ca", value] unless value.empty?
    when "author_ca"
      value = row["ca"].to_s.strip
      return ["ca", value] unless value.empty?
    end
    [nil, nil]
  end

  def row_year_range(row)
    start_year = integer_or_nil(row["evidence_start"])
    end_year = integer_or_nil(row["evidence_end"])
    if start_year || end_year
      left, right = [start_year || end_year, end_year || start_year].minmax
      return [left, right]
    end

    parse_circa(row["ca"])
  end

  def parse_circa(value)
    text = value.to_s.strip.delete(" ")
    return nil if text.empty?

    if (match = text.match(/\A(前)?(\d+)年\z/))
      year = match[1] ? -match[2].to_i : match[2].to_i
      return [year, year]
    end

    match = text.match(/\A(前)?(\d+)[–—-](前)?(\d+)年\z/)
    return nil unless match

    first = match[1] ? -match[2].to_i : match[2].to_i
    second = match[3] ? -match[4].to_i : match[4].to_i
    [first, second].minmax
  end

  def format_circa(start_year, end_year)
    left, right = [start_year.to_i, end_year.to_i].minmax
    return left.negative? ? "前#{left.abs}年" : "#{left}年" if left == right

    if right.negative?
      "前#{left.abs}–前#{right.abs}年"
    elsif left.negative?
      "前#{left.abs}–#{right}年"
    else
      "#{left}–#{right}年"
    end
  end

  def path_chronology_context(path_text)
    parts = path_text.split("/")
    clean_index = parts.index("clean")
    return nil unless clean_index

    context = nil
    labels = []
    Array(parts[(clean_index + 1)...-2]).each do |value|
      range = period_range_for_value(value)
      next unless range

      if context.nil?
        context = { start: range[0], end: range[1] }
        labels << value
        next
      end

      start_year = [context[:start], range[0]].max
      end_year = [context[:end], range[1]].min

      # A deeper folder can share a name with a later dynasty (for example the
      # Warring States polity 宋 or 晉).  If its modern dynastic range conflicts
      # with the chronology already established by its parents, ignore that
      # homonymous interpretation instead of destroying the path context.
      next if start_year > end_year

      context = { start: start_year, end: end_year }
      labels << value
    end

    return nil unless context

    context.merge(label: labels.join("/"))
  end

  def period_range_for_value(value)
    forms = normalized_polity_forms(value)
    return nil if forms.empty?

    CbdbAutoAnnotatorStaticNames::PERIOD_RANGES.each do |labels, start_year, end_year|
      return [start_year, end_year] if Array(labels).any? { |label| forms.include?(label.to_s) }
    end
    nil
  end

  def normalized_polity_forms(value)
    raw = value.to_s.strip
    return [] if raw.empty?

    output = [raw]
    output << raw.sub(/朝\z/, "") if raw.end_with?("朝")
    output << raw.each_char.drop(1).join if raw.start_with?("大") && raw.each_char.count > 1
    stripped = raw.sub(/\A大/, "").sub(/朝\z/, "")
    output << stripped unless stripped.empty?
    output.uniq
  end

  def ranges_overlap?(left_start, left_end, right_start, right_end)
    left_start <= right_end && right_start <= left_end
  end

  def write_metadata(path, metadata)
    body = "\xEF\xBB\xBF".b + (JSON.pretty_generate(metadata) + "\n").encode(Encoding::UTF_8).b
    temporary = path.dirname.join(".fhwc-date-checkpoint-#{Process.pid}-#{Thread.current.object_id}.tmp")

    WRITE_RETRIES.times do |attempt|
      begin
        temporary.binwrite(body)
        File.rename(temporary, path)
        return
      rescue Errno::EACCES, Errno::EBUSY, Errno::EPERM => e
        raise if attempt == WRITE_RETRIES - 1
        @logger&.warn(
          "[corpus_metadata_dates checkpoint] write retry #{attempt + 1}/#{WRITE_RETRIES} for #{path}: " \
          "#{e.class}: #{e.message}"
        )
        sleep(WRITE_RETRY_SLEEP)
      ensure
        FileUtils.rm_f(temporary) if temporary.exist?
      end
    end
  end

  def review(row, reason, extra = {})
    @review_rows << {
      path: row["path"],
      action: row["action"],
      title: row["title"],
      reason: reason,
      date: row["date"],
      ca: row["ca"],
      evidence: row["evidence"],
      evidence_start: row["evidence_start"],
      evidence_end: row["evidence_end"]
    }.merge(extra)
  end

  def write_review_report!(counters)
    stamp = Time.now.utc.strftime("checkpoint_%Y%m%dT%H%M%SZ")
    directory = @report_root.join(stamp)
    FileUtils.mkdir_p(directory)

    write_tsv(directory.join("review.tsv"), @review_rows)
    summary = counters.sort.to_h.merge(
      "mode" => @apply ? "apply" : "audit",
      "source_report" => @report_path.to_s
    )
    write_utf8_bom(directory.join("summary.json"), JSON.pretty_generate(summary) + "\n")
    directory
  end

  def write_tsv(path, rows)
    headers = rows.flat_map(&:keys).map(&:to_s).uniq
    File.open(path, "wb") do |io|
      io.write("\xEF\xBB\xBF".b)
      if headers.empty?
        io.write("\n".b)
        next
      end
      csv = CSV.new(io, col_sep: "\t", write_headers: true, headers: headers)
      rows.each { |row| csv << headers.map { |header| row[header.to_sym] || row[header] } }
      csv.close
    end
  end

  def write_utf8_bom(path, text)
    path.binwrite("\xEF\xBB\xBF".b + text.encode(Encoding::UTF_8).b)
  end

  def print_progress(index, counters)
    verb = @apply ? "written" : "would write"
    value = @apply ? counters["written"] : counters["would_write"]
    puts "[corpus_metadata_dates checkpoint] #{index}: #{value} #{verb}, " \
      "#{counters['deferred_self_regnal']} self-regnal deferred, " \
      "#{counters['author_path_rejected']} author/path rejected"
  end

  def present_value?(value)
    !value.nil? && !value.to_s.strip.empty?
  end

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end
end
