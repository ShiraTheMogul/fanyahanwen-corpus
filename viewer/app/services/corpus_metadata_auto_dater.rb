# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "set"
require "time"

# Corpus maintenance pass which materializes a small chronology value into each
# work's metadata.json. It follows a deliberately simple evidence ladder:
#
#   1. self-referential regnal/era date in the work -> date: "1544年"
#   2. known author -> ca: author's compatible lifespan/floruit range
#   3. no author -> ca: polity/dynasty range
#
# Existing date/year fields are never overwritten. The only generated metadata
# keys are +date+ or +ca+. The task is dry-run by default; filesystem moves and
# duplicate merges require separate explicit switches.
class CorpusMetadataAutoDater
  DATE_KEYS = %w[date year year_start year_end].freeze
  SEXAGENARY = /[甲乙丙丁戊己庚辛壬癸][子丑寅卯辰巳午未申酉戌亥]/.freeze
  NUMERIC_YEAR_TOKEN = /[元〇零○一二三四五六七八九十百千兩两廿卅卌0-9]{1,8}年/.freeze
  SENTENCE_BOUNDARY = /[。！？!?；;\n\r]/.freeze

  # These are structural signals, not a claim that every occurrence of a word is
  # self-dating. The scorer also requires position/genre evidence.
  SELF_REFERENCE_MARKERS = Regexp.union(
    /謹(?:序|識|识|誌|志|記|记|書|书|題|题|奏|上)/,
    /(?:為|爲|作|撰)(?:之)?(?:序|跋|記|记|誌|志|書|书|題|题)/,
    /(?:余|予|愚|僕|仆|臣|某).{0,24}(?:序|跋|記|记|誌|志|書|书|題|题|撰|作|奏|上)/m,
    /(?:乃|遂)(?:為|爲|作|撰).{0,8}(?:序|跋|記|记|誌|志|書|书|題|题)/m,
    /(?:成於|成于|作於|作于|撰於|撰于|撰成|成書於|成书于)/,
    /(?:制曰|詔曰|诏曰|敕曰|上諭|上谕|奉敕|奉詔|奉诏|謹奏|谨奏)/
  ).freeze
  FIRST_PERSON_MARKERS = /(?:余|予|愚|吾|臣|臣等|僕|仆|某)/.freeze
  NARRATIVE_MARKERS = /(?:昔|先是|初|其年|是歲|是岁|明年|越\s*[一二三四五六七八九十]*年|後|后)/.freeze
  PREFACE_GENRE = /(?:序|跋|後序|后序|記|记|誌|志|題記|题记|書後|书后)/.freeze
  OFFICIAL_GENRE = /(?:詔|诏|制|敕|諭|谕|奏|表|疏|啟|启|檄|牒)/.freeze

  Result = Data.define(
    :scanned, :dated, :circa_author, :circa_polity, :unchanged,
    :move_candidates, :moved, :duplicate_candidates, :merged, :report_dir
  )

  def initialize(
    root:,
    store: HistoricalAuthorityStore.default,
    person_repository: nil,
    resolver: nil,
    logger: Rails.logger,
    apply: false,
    apply_moves: false,
    merge_duplicates: false,
    future_margin: 25,
    progress_every: 1_000,
    path_filter: nil,
    limit: nil,
    report_root: nil
  )
    @root = Pathname(root).realpath
    @store = store
    @people = person_repository || HistoricalPersonRepository.new(store: store)
    @resolver = resolver || HistoricalDateResolver.new(store: store)
    @logger = logger
    @apply = apply
    @apply_moves = apply_moves
    @merge_duplicates = merge_duplicates
    @future_margin = Integer(future_margin)
    @progress_every = [Integer(progress_every), 1].max
    @path_filter = path_filter.to_s.strip.presence
    @limit = limit.to_i if limit
    @report_root = Pathname(report_root || Rails.root.join("tmp", "corpus_metadata_auto_dates"))
    @era_windows = nil
    @rows = []
    @move_rows = []
    @duplicate_rows = []
  end

  def run!
    counters = Hash.new(0)
    paths = metadata_paths
    paths = paths.first(@limit) if @limit&.positive?

    paths.each_with_index do |metadata_path, index|
      counters["scanned"] += 1
      process_metadata!(metadata_path, counters)
      if ((index + 1) % @progress_every).zero?
        puts "[corpus_metadata_dates] #{index + 1}/#{paths.length}: " \
          "#{counters['dated']} exact, #{counters['circa_author']} author ca, " \
          "#{counters['circa_polity']} polity ca, #{counters['move_candidates']} move candidates"
      end
    end

    report_dir = write_reports!
    Result.new(
      scanned: counters["scanned"],
      dated: counters["dated"],
      circa_author: counters["circa_author"],
      circa_polity: counters["circa_polity"],
      unchanged: counters["unchanged"],
      move_candidates: counters["move_candidates"],
      moved: counters["moved"],
      duplicate_candidates: counters["duplicate_candidates"],
      merged: counters["merged"],
      report_dir: report_dir
    )
  end

  private

  def metadata_paths
    paths = Dir.glob(@root.join("**", "metadata.json").to_s).map { |path| Pathname(path) }
      .select { |path| clean_metadata_path?(path) }
      .sort_by(&:to_s)
    return paths if @path_filter.blank?

    paths.select do |path|
      relative(path).include?(@path_filter) || path.dirname.basename.to_s.include?(@path_filter)
    end
  end

  def clean_metadata_path?(path)
    relative(path).split("/").include?("clean")
  rescue ArgumentError
    false
  end

  def process_metadata!(metadata_path, counters)
    metadata = read_metadata(metadata_path)
    if metadata.empty?
      record(metadata_path, "invalid_metadata", nil, nil)
      counters["unchanged"] += 1
      return
    end

    before = metadata.dup
    evidence = nil

    unless explicit_date_locked?(metadata)
      # An existing date_label is already metadata-level evidence. Convert it
      # before scanning the prose, but only when the resolver reaches one year.
      evidence = exact_from_date_label(metadata)
      evidence ||= exact_from_self_reference(metadata_path, metadata)

      if evidence
        metadata.delete("ca")
        metadata["date"] = format_exact_year(evidence.fetch(:year))
        counters["dated"] += 1
      elsif metadata["ca"].to_s.strip.empty?
        if author_names(metadata).any?
          if (author = author_circa(metadata))
            metadata["ca"] = format_circa(author.fetch(:start), author.fetch(:end))
            evidence = author
            counters["circa_author"] += 1
          end
        elsif (polity = polity_circa(metadata))
          metadata["ca"] = format_circa(polity.fetch(:start), polity.fetch(:end))
          evidence = polity
          counters["circa_polity"] += 1
        end
      end
    end

    changed = metadata != before
    write_metadata(metadata_path, metadata) if changed && @apply
    counters["unchanged"] += 1 unless changed
    record(metadata_path, changed ? evidence&.fetch(:kind, "updated") : "unchanged", metadata, evidence)

    chronology = chronology_from_metadata(metadata) || evidence_range(evidence)
    plan_or_apply_move!(metadata_path, metadata, chronology, evidence, counters) if chronology
  rescue StandardError => e
    @logger&.warn("[corpus_metadata_dates] skipped #{relative(metadata_path)}: #{e.class}: #{e.message}")
    record(metadata_path, "error", nil, { error: "#{e.class}: #{e.message}" })
    counters["unchanged"] += 1
  end

  def explicit_date_locked?(metadata)
    DATE_KEYS.any? { |key| present_value?(metadata[key]) }
  end

  def exact_from_date_label(metadata)
    label = metadata["date_label"].to_s.strip
    return nil if label.empty?

    resolution = @resolver.resolve(metadata: resolver_metadata(metadata, label))
    return nil unless resolution&.resolved?
    return nil unless resolution.year_start && resolution.year_start == resolution.year_end

    { kind: "date_label", year: resolution.year_start, surface: label }
  rescue StandardError
    nil
  end

  def exact_from_self_reference(metadata_path, metadata)
    documents = work_documents(metadata_path, metadata)
    return nil if documents.empty?

    candidates = documents.flat_map do |document_path|
      text = read_document_body(document_path)
      self_dating_candidates(text, metadata).map do |candidate|
        candidate.merge(document: relative(document_path))
      end
    end
    choose_self_date(candidates)
  end

  def self_dating_candidates(text, metadata)
    candidates = numeric_regnal_candidates(text, metadata)
    candidates.concat(sexagenary_candidates(text, metadata))
    candidates.select { |candidate| candidate.fetch(:score) >= 5 }
  end

  def numeric_regnal_candidates(text, metadata)
    output = []
    text.scan(NUMERIC_YEAR_TOKEN) do
      match = Regexp.last_match
      index = match.begin(0)
      segment_start = clause_start(text, index, 48)
      segment = text[segment_start...match.end(0)]
      resolution = @resolver.resolve(metadata: resolver_metadata(metadata, segment))
      next unless resolution&.resolved?
      next unless resolution.year_start && resolution.year_start == resolution.year_end
      next unless %w[era ruler].include?(resolution.authority_kind.to_s)

      score = self_reference_score(text, index, match.end(0), metadata)
      output << {
        kind: "self_regnal",
        year: resolution.year_start,
        score: score,
        surface: resolution.date_label.to_s.presence || segment,
        authority_name: resolution.authority_name
      }
    rescue StandardError
      next
    end
    output
  end

  def sexagenary_candidates(text, metadata)
    matches = []
    text.scan(SEXAGENARY) { matches << Regexp.last_match.dup }
    return [] if matches.empty?

    explicit_windows = matches.flat_map do |match|
      era_windows_immediately_before(text, match.begin(0), metadata)
    end.uniq { |window| [window[:source], window[:id]] }

    matches.filter_map do |match|
      own_windows = era_windows_immediately_before(text, match.begin(0), metadata)
      windows = own_windows.presence || explicit_windows
      next if windows.blank?

      years = windows.flat_map do |window|
        sexagenary_years(match[0], window.fetch(:start), window.fetch(:end))
      end.uniq
      next unless years.one?

      {
        kind: "self_regnal_sexagenary",
        year: years.first,
        score: self_reference_score(text, match.begin(0), match.end(0), metadata),
        surface: match[0],
        authority_name: own_windows.first&.dig(:label)
      }
    end
  end

  def era_windows_immediately_before(text, index, metadata)
    prefix = text[[index - 12, 0].max...index].to_s
    han_tail = prefix[/\p{Han}{1,8}\z/].to_s
    return [] if han_tail.empty?

    names = 2.upto([8, han_tail.each_char.count].min).map { |length| han_tail.each_char.to_a.last(length).join }.reverse
    names.each do |name|
      windows = era_windows.fetch(name, []).select { |window| era_window_compatible?(window, metadata) }
      return windows if windows.any?
    end
    []
  end

  def era_windows
    return @era_windows if @era_windows

    @era_windows = Hash.new { |hash, key| hash[key] = [] }
    return @era_windows unless @store.respond_to?(:historical_available?) && @store.historical_available?

    @store.with_database do |db|
      rows = db.execute(<<~SQL)
        SELECT n.name_chn, n.source, n.era_id,
               e.label, e.local_label, e.country, e.start_year, e.end_year,
               e.local_use_start_year, e.local_use_end_year, e.polities_json
        FROM historical.era_names n
        JOIN historical.eras e ON e.source = n.source AND e.era_id = n.era_id
        WHERE n.name_length BETWEEN 2 AND 8
      SQL
      rows.each do |row|
        start_year = integer_or_nil(row["local_use_start_year"] || row["start_year"])
        end_year = integer_or_nil(row["local_use_end_year"] || row["end_year"])
        next unless start_year && end_year
        next if start_year <= 0 || end_year <= 0 # sexagenary arithmetic here is CE-only

        @era_windows[row["name_chn"].to_s] << {
          source: row["source"].to_s,
          id: row["era_id"].to_s,
          label: row["local_label"].to_s.presence || row["label"].to_s,
          country: row["country"].to_s,
          start: start_year,
          end: end_year,
          polities: parse_json_array(row["polities_json"])
        }
      end
    end
    @era_windows
  rescue StandardError => e
    @logger&.warn("[corpus_metadata_dates] era-window preload unavailable: #{e.class}: #{e.message}")
    @era_windows ||= {}
  end

  def era_window_compatible?(window, metadata)
    country = metadata_country(metadata)
    return false if country.present? && window[:country].present? && country != window[:country]

    polity = metadata["polity"].to_s.strip
    return true if polity.empty? || window[:polities].empty?

    wanted = normalized_polity_forms(polity)
    window[:polities].any? { |value| (normalized_polity_forms(value) & wanted).any? }
  end

  def sexagenary_years(name, start_year, end_year)
    stems = %w[甲 乙 丙 丁 戊 己 庚 辛 壬 癸]
    branches = %w[子 丑 寅 卯 辰 巳 午 未 申 酉 戌 亥]
    target = nil
    60.times do |offset|
      pair = stems[offset % 10] + branches[offset % 12]
      if pair == name
        target = offset
        break
      end
    end
    return [] unless target

    (start_year..end_year).select { |year| ((year - 1984) % 60) == target }
  end

  def self_reference_score(text, start_index, end_index, metadata)
    length = [text.length, 1].max
    ratio = start_index.to_f / length
    boundary = ratio <= 0.10 || ratio >= 0.80
    context_start = [start_index - 100, 0].max
    context_end = [end_index + 180, text.length].min
    context = text[context_start...context_end].to_s
    title = [metadata["title"], metadata["work_base_title"]].join(" ")

    score = 0
    score += 3 if boundary
    score += 2 if title.match?(PREFACE_GENRE)
    score += 2 if title.match?(OFFICIAL_GENRE)
    score += 4 if context.match?(SELF_REFERENCE_MARKERS)
    score += 2 if context.match?(FIRST_PERSON_MARKERS)
    score -= 2 if context[0, [start_index - context_start, 100].max].to_s.match?(NARRATIVE_MARKERS)

    # Prefaces/records need a local composition signal. Official documents can
    # use a boundary date plus their genre as the structural signal.
    unless title.match?(OFFICIAL_GENRE) && boundary
      score = [score, 4].min unless context.match?(SELF_REFERENCE_MARKERS)
    end
    score
  end

  def choose_self_date(candidates)
    return nil if candidates.empty?

    ordered = candidates.sort_by { |candidate| [-candidate.fetch(:score), candidate.fetch(:year), candidate.fetch(:document, "")] }
    best = ordered.first
    near = ordered.select { |candidate| candidate.fetch(:score) >= best.fetch(:score) - 1 }
    return nil if near.map { |candidate| candidate.fetch(:year) }.uniq.length > 1

    best
  end

  def author_circa(metadata)
    names = author_names(metadata)
    return nil if names.empty?

    ranges = names.filter_map do |name|
      set = @people.find_candidates(names: [name], metadata: metadata)
      dated = Array(set.candidates).select do |candidate|
        candidate["year_start"] || candidate["year_end"]
      end
      high = dated.select { |candidate| candidate["confidence"].to_s == "high" }
      pool = high.any? ? high : dated
      pool = pool.select { |candidate| person_candidate_compatible?(candidate, metadata) }
      next unless pool.one?

      candidate = pool.first
      start_year = integer_or_nil(candidate["year_start"] || candidate["year_end"])
      end_year = integer_or_nil(candidate["year_end"] || candidate["year_start"])
      next unless start_year && end_year
      { start: [start_year, end_year].min, end: [start_year, end_year].max, candidate: candidate }
    end
    return nil if ranges.empty?
    return nil unless ranges.length == names.length

    left = ranges.map { |range| range[:start] }.max
    right = ranges.map { |range| range[:end] }.min
    return nil if left > right

    {
      kind: "author_ca",
      start: left,
      end: right,
      author_names: names,
      author_polity: ranges.filter_map { |range| range.dig(:candidate, "polity") }.uniq.one? ? ranges.first.dig(:candidate, "polity") : nil
    }
  end

  def person_candidate_compatible?(candidate, metadata)
    candidate_polity = candidate["polity"].to_s.strip
    return true if candidate_polity.empty?

    values = [metadata["polity"], metadata["period"]].map(&:to_s).reject(&:empty?)
    return true if values.empty?

    candidate_forms = normalized_polity_forms(candidate_polity)
    values.any? { |value| (candidate_forms & normalized_polity_forms(value)).any? }
  end

  def polity_circa(metadata)
    [metadata["polity"], metadata["period"]].each do |value|
      range = period_range_for_value(value)
      next unless range
      return { kind: "polity_ca", start: range[0], end: range[1], polity: value.to_s }
    end

    authority_polity_range(metadata)
  end

  def authority_polity_range(metadata)
    polity = metadata["polity"].to_s.strip
    return nil if polity.empty? || !@store.respond_to?(:historical_available?) || !@store.historical_available?

    wanted = normalized_polity_forms(polity)
    windows = era_windows.values.flatten.select do |window|
      era_window_compatible?(window, metadata) &&
        window[:polities].any? { |value| (normalized_polity_forms(value) & wanted).any? }
    end
    return nil if windows.empty?

    { kind: "polity_ca", start: windows.map { |window| window[:start] }.min, end: windows.map { |window| window[:end] }.max, polity: polity }
  end

  def period_range_for_value(value)
    forms = normalized_polity_forms(value)
    return nil if forms.empty?

    ranges = if defined?(CbdbAutoAnnotatorStaticNames::PERIOD_RANGES)
      CbdbAutoAnnotatorStaticNames::PERIOD_RANGES
    else
      []
    end
    ranges.each do |labels, start_year, end_year|
      return [start_year, end_year] if Array(labels).any? { |label| forms.include?(label.to_s) }
    end
    nil
  end

  def normalized_polity_forms(value)
    raw = value.to_s.strip
    return [] if raw.empty?

    output = [raw]
    output << raw.sub(/朝\z/, "") if raw.end_with?("朝")
    if raw.start_with?("大") && raw.each_char.count > 1
      output << raw.each_char.drop(1).join
    end
    stripped = raw.sub(/\A大/, "").sub(/朝\z/, "")
    output << stripped unless stripped.empty?
    output.uniq
  end

  def author_names(metadata)
    values = Array(metadata["authors"]).filter_map do |item|
      if item.is_a?(Hash)
        item["name"].to_s.strip.presence
      else
        item.to_s.strip.presence
      end
    end
    scalar = metadata["author"].to_s.strip.presence
    values << scalar if scalar
    values.uniq
  end

  def work_documents(metadata_path, metadata)
    folder = metadata_path.dirname
    declared = Array(metadata["documents"]).filter_map do |document|
      next unless document.is_a?(Hash)
      explicit = document["path"].to_s.tr("\\", "/").sub(%r{\A/+}, "")
      candidate = explicit.present? ? @root.join(explicit) : folder.join(document["file"].to_s)
      candidate if candidate.file?
    end
    return declared.uniq if declared.any?

    Dir.glob(folder.join("*.txt").to_s).map { |path| Pathname(path) }.sort
  end

  def read_document_body(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise Encoding::InvalidByteSequenceError, "invalid UTF-8" unless raw.valid_encoding?

    raw.sub(/\A\uFEFF/, "")
  end

  def resolver_metadata(metadata, date_text)
    {
      "date_text" => date_text,
      "date_label" => date_text,
      "corpus_root" => metadata["corpus_root"],
      "nation" => metadata["nation"],
      "period" => metadata["period"],
      "polity" => metadata["polity"],
      "region" => metadata["region"]
    }.compact
  end

  def clause_start(text, index, limit)
    cursor = index - 1
    floor = [index - limit, 0].max
    while cursor >= floor
      break if text[cursor].match?(SENTENCE_BOUNDARY)
      cursor -= 1
    end
    cursor + 1
  end

  def chronology_from_metadata(metadata)
    if (year = integer_or_nil(metadata["year"]))
      return { start: year, end: year, kind: "metadata_year" }
    end
    start_year = integer_or_nil(metadata["year_start"])
    end_year = integer_or_nil(metadata["year_end"])
    if start_year || end_year
      return { start: start_year || end_year, end: end_year || start_year, kind: "metadata_year_range" }
    end
    if (year = parse_exact_date(metadata["date"]))
      return { start: year, end: year, kind: "metadata_date" }
    end
    if (bounds = parse_circa(metadata["ca"]))
      return { start: bounds[0], end: bounds[1], kind: "metadata_ca" }
    end
    nil
  end

  def evidence_range(evidence)
    return nil unless evidence
    if evidence[:year]
      { start: evidence[:year], end: evidence[:year], kind: evidence[:kind] }
    elsif evidence[:start] || evidence[:end]
      { start: evidence[:start] || evidence[:end], end: evidence[:end] || evidence[:start], kind: evidence[:kind] }
    end
  end

  def plan_or_apply_move!(metadata_path, metadata, chronology, evidence, counters)
    current_range = period_range_for_value(metadata["polity"]) || period_range_for_value(metadata["period"])
    return unless current_range
    return unless chronology[:start] && chronology[:start] > current_range[1] + @future_margin

    target = move_target(metadata_path, metadata, chronology, evidence)
    return unless target

    counters["move_candidates"] += 1
    @move_rows << {
      path: relative(metadata_path.dirname),
      current_period: metadata["period"],
      current_polity: metadata["polity"],
      chronology_start: chronology[:start],
      chronology_end: chronology[:end],
      target: relative(target),
      reason: chronology[:kind]
    }

    source_folder = metadata_path.dirname
    if target.exist?
      counters["duplicate_candidates"] += 1
      handle_duplicate!(source_folder, target, counters)
      return
    end

    return unless @apply && @apply_moves

    unless movable_leaf_folder?(source_folder)
      @move_rows.last[:reason] = "#{@move_rows.last[:reason]}:nested_metadata_review"
      return
    end

    FileUtils.mkdir_p(target.parent)
    FileUtils.mv(source_folder.to_s, target.to_s)
    counters["moved"] += 1
  end

  def move_target(metadata_path, metadata, chronology, evidence)
    parts = relative(metadata_path).split("/")
    clean_index = parts.index("clean")
    return nil unless clean_index && parts.length >= clean_index + 3

    clean_root = @root.join(*parts[0..clean_index])
    year = ((chronology[:start] + chronology[:end]) / 2.0).round
    period_candidates = Dir.children(clean_root).filter_map do |name|
      path = clean_root.join(name)
      next unless path.directory?
      range = period_range_for_value(name)
      next unless range && year.between?(range[0], range[1])
      [path, range]
    rescue SystemCallError
      nil
    end
    return nil if period_candidates.empty?

    period_path, = period_candidates.min_by { |_path, range| range[1] - range[0] }
    children = Dir.children(period_path).map { |name| period_path.join(name) }.select(&:directory?)
    desired_polity = evidence.to_h[:author_polity].to_s.presence
    polity_path = if desired_polity
      wanted = normalized_polity_forms(desired_polity)
      children.find { |child| (normalized_polity_forms(child.basename.to_s) & wanted).any? }
    end
    polity_path ||= children.first if children.one?
    return nil unless polity_path

    polity_path.join(metadata_path.dirname.basename)
  rescue SystemCallError, ArgumentError
    nil
  end


  def movable_leaf_folder?(folder)
    Dir.glob(folder.join("**", "metadata.json").to_s).none? do |path|
      Pathname(path).expand_path != folder.join("metadata.json").expand_path
    end
  rescue SystemCallError
    false
  end

  def handle_duplicate!(source, destination, counters)
    text_similarity = folder_text_similarity(source, destination)
    metadata_similarity = folder_metadata_similarity(source, destination)
    same_source = same_source_identity?(source, destination)
    mergeable = text_similarity >= 0.95 || (text_similarity >= 0.85 && metadata_similarity >= 0.85) || same_source
    source_time = folder_timestamp(source)
    destination_time = folder_timestamp(destination)

    @duplicate_rows << {
      source: relative(source),
      destination: relative(destination),
      text_similarity: format("%.4f", text_similarity),
      metadata_similarity: format("%.4f", metadata_similarity),
      same_source_identity: same_source,
      source_timestamp: source_time&.iso8601,
      destination_timestamp: destination_time&.iso8601,
      mergeable: mergeable,
      latest_known: source_time && destination_time ? (source_time > destination_time ? "source" : "destination") : "unknown"
    }

    return unless @merge_duplicates && mergeable && source_time && destination_time && source_time != destination_time

    if source_time > destination_time
      FileUtils.rm_rf(destination)
      FileUtils.mv(source.to_s, destination.to_s)
    else
      FileUtils.rm_rf(source)
    end
    counters["merged"] += 1
    counters["moved"] += 1
  end

  def folder_text_similarity(left, right)
    a = normalized_folder_text(left)
    b = normalized_folder_text(right)
    return 1.0 if a == b && !a.empty?
    return 0.0 if a.empty? || b.empty?

    a_set = shingles(a, 8)
    b_set = shingles(b, 8)
    union = a_set | b_set
    return 0.0 if union.empty?

    (a_set & b_set).length.to_f / union.length
  end

  def normalized_folder_text(folder)
    Dir.glob(folder.join("**", "*.txt").to_s).sort.map do |path|
      raw = File.binread(path).force_encoding(Encoding::UTF_8)
      raw = raw.scrub unless raw.valid_encoding?
      raw.delete("\uFEFF").gsub(/[\s\p{P}\p{S}]+/u, "")
    end.join
  end

  def shingles(text, size)
    chars = text.each_char.to_a
    return Set.new([text]) if chars.length < size
    Set.new(chars.each_cons(size).map(&:join))
  end

  def folder_metadata_similarity(left, right)
    a = read_metadata(left.join("metadata.json"))
    b = read_metadata(right.join("metadata.json"))
    score = 0.0
    score += 0.45 if normalized_title(a) == normalized_title(b) && normalized_title(a).present?

    a_authors = author_names(a).to_set
    b_authors = author_names(b).to_set
    score += 0.25 if a_authors.any? && b_authors.any? && (a_authors & b_authors).any?

    a_categories = Array(a["source_categories"]).map(&:to_s).to_set
    b_categories = Array(b["source_categories"]).map(&:to_s).to_set
    if a_categories.any? && b_categories.any?
      union = a_categories | b_categories
      score += 0.10 * ((a_categories & b_categories).length.to_f / union.length)
    end

    score += 0.20 if same_source_identity_hash?(a, b)
    score
  end

  def same_source_identity?(left, right)
    same_source_identity_hash?(read_metadata(left.join("metadata.json")), read_metadata(right.join("metadata.json")))
  end

  def same_source_identity_hash?(left, right)
    left_values = source_identity_values(left)
    right_values = source_identity_values(right)
    left_values.any? && right_values.any? && (left_values & right_values).any?
  end

  def source_identity_values(metadata)
    values = []
    values << metadata["page_title"].to_s.strip if present_value?(metadata["page_title"])
    Array(metadata["sources"]).each do |source|
      next unless source.is_a?(Hash)
      %w[url source_url page_title].each do |key|
        values << source[key].to_s.strip if present_value?(source[key])
      end
    end
    values.reject(&:empty?).to_set
  end

  def folder_timestamp(folder)
    metadata = read_metadata(folder.join("metadata.json"))
    timestamps = []
    collect_timestamps(metadata, timestamps)
    timestamps.max
  end

  def collect_timestamps(value, output, key = nil)
    case value
    when Hash
      value.each { |child_key, child| collect_timestamps(child, output, child_key.to_s) }
    when Array
      value.each { |child| collect_timestamps(child, output, key) }
    else
      return unless key.to_s.match?(/(?:scraped|retrieved|downloaded|updated|modified).*(?:at|date|utc)?\z/i)
      output << Time.parse(value.to_s)
    end
  rescue ArgumentError
    nil
  end

  def normalized_title(metadata)
    (metadata["work_base_title"].presence || metadata["title"].to_s).to_s.gsub(/[\s《》〈〉「」『』]/, "")
  end

  def metadata_country(metadata)
    haystack = [metadata["corpus_root"], metadata["nation"], metadata["period"], metadata["polity"], metadata["region"]].map(&:to_s).join(" ")
    HistoricalDateResolver::COUNTRY_HINTS.each do |hint, country|
      return country if haystack.include?(hint)
    end
    nil
  end

  def format_exact_year(year)
    year.to_i < 0 ? "前#{year.to_i.abs}年" : "#{year.to_i}年"
  end

  def format_circa(start_year, end_year)
    left, right = [start_year.to_i, end_year.to_i].minmax
    return format_exact_year(left) if left == right

    if right < 0
      "前#{left.abs}–前#{right.abs}年"
    elsif left < 0
      "前#{left.abs}–#{right}年"
    else
      "#{left}–#{right}年"
    end
  end

  def parse_exact_date(value)
    text = value.to_s.strip
    if (match = text.match(/\A前\s*(\d{1,4})\s*年/))
      return -match[1].to_i
    end
    if (match = text.match(/\A(\d{1,4})\s*年/))
      return match[1].to_i
    end
    nil
  end

  def parse_circa(value)
    text = value.to_s.strip.sub(/\A(?:ca\.?|circa|約|约)\s*/i, "").gsub(/[‐‑‒—−-]/, "–")
    if (match = text.match(/\A前\s*(\d{1,4})\s*–\s*前\s*(\d{1,4})\s*年?\z/))
      return [-match[1].to_i, -match[2].to_i].minmax
    end
    if (match = text.match(/\A前\s*(\d{1,4})\s*–\s*(\d{1,4})\s*年?\z/))
      return [-match[1].to_i, match[2].to_i].minmax
    end
    if (match = text.match(/\A(\d{1,4})\s*–\s*(\d{1,4})\s*年?\z/))
      return [match[1].to_i, match[2].to_i].minmax
    end
    if (year = parse_exact_date(text))
      return [year, year]
    end
    nil
  end

  def read_metadata(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise JSON::ParserError, "invalid UTF-8" unless raw.valid_encoding?
    JSON.parse(raw.sub(/\A\uFEFF/, ""))
  end

  def write_metadata(path, metadata)
    body = JSON.pretty_generate(metadata) + "\n"
    path.binwrite("\xEF\xBB\xBF".b + body.encode(Encoding::UTF_8).b)
  end

  def record(path, action, metadata, evidence)
    @rows << {
      path: relative(path),
      action: action,
      title: metadata.to_h["title"],
      period: metadata.to_h["period"],
      polity: metadata.to_h["polity"],
      date: metadata.to_h["date"],
      ca: metadata.to_h["ca"],
      evidence: evidence.to_h[:surface] || evidence.to_h[:kind],
      evidence_year: evidence.to_h[:year],
      evidence_start: evidence.to_h[:start],
      evidence_end: evidence.to_h[:end]
    }
  end

  def write_reports!
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    directory = @report_root.join(stamp)
    FileUtils.mkdir_p(directory)
    write_tsv(directory.join("dates.tsv"), @rows)
    write_tsv(directory.join("moves.tsv"), @move_rows)
    write_tsv(directory.join("duplicates.tsv"), @duplicate_rows)
    directory
  end

  def write_tsv(path, rows)
    headers = rows.flat_map(&:keys).map(&:to_s).uniq
    File.open(path, "wb") do |io|
      io.write("\xEF\xBB\xBF".b)
      csv = CSV.new(io, col_sep: "\t", write_headers: true, headers: headers)
      rows.each { |row| csv << headers.map { |header| row[header.to_sym] || row[header] } }
      csv.close
    end
  end

  def parse_json_array(value)
    parsed = JSON.parse(value.to_s)
    Array(parsed).map(&:to_s)
  rescue JSON::ParserError, TypeError
    []
  end

  def present_value?(value)
    !value.nil? && !value.to_s.strip.empty?
  end

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end

  def relative(path)
    Pathname(path).relative_path_from(@root).to_s.tr("\\", "/")
  rescue ArgumentError
    path.to_s
  end
end
