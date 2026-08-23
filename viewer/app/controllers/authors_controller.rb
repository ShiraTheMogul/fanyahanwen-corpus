# frozen_string_literal: true

class AuthorsController < ApplicationController
  def index
    @repository = HistoricalPersonRepository.new
    @source_path = normalized_source_path(params[:path])
    @metadata = metadata_for_path(@source_path)
    @author_values = if params[:name].present?
      [params[:name].to_s]
    else
      author_values(@metadata)
    end

    if request.format.json?
      render json: author_link_payload
      return
    end

    @corpus_people = corpus_people_for(@author_values)
    @candidate_set = safe_find_candidates(names: @author_values, metadata: @metadata)
  rescue SecurityError
    render_index_error(I18n.t("authority.errors.bad_path"), :bad_request)
  rescue StandardError => e
    Rails.logger.warn("[authority] author candidate lookup failed: #{e.class}: #{e.message}")
    render_index_error(I18n.t("authority.errors.unavailable"), :service_unavailable)
  end

  def show
    @repository = HistoricalPersonRepository.new
    @person = @repository.fetch(source: params[:source], id: params[:id])
    unless @person
      render plain: I18n.t("authority.errors.not_found"), status: :not_found
      return
    end
    @corpus_contributions = @repository.corpus_contributions(@person)
    if @person["source"].to_s == "corpus"
      @related_candidates = safe_find_candidates(names: [@person["label"]], metadata: {})
    end
  rescue StandardError => e
    Rails.logger.warn("[authority] author page failed: #{e.class}: #{e.message}")
    render plain: I18n.t("authority.errors.unavailable"), status: :service_unavailable
  end

  private

  def author_link_payload
    matches = @author_values.map do |name|
      # Prefer the corpus-native profile because corpus authorship is an explicit
      # repository fact. If that catalogue is stale or an external identity is
      # ambiguous, still return a Find Authors destination so the header never
      # degenerates into unexplained plain text.
      corpus_person = @repository.corpus_profile(name)
      profile = if corpus_person
        {
          "source" => "corpus",
          "id" => corpus_person["id"].to_s,
          "label" => corpus_person["label"].to_s,
          "confidence" => "corpus_credit"
        }
      else
        set = safe_find_candidates(names: [name], metadata: @metadata)
        candidate = direct_candidate(set.candidates)
        if candidate
          {
            "source" => candidate["authority_source"].to_s,
            "id" => candidate["id"].to_s,
            "label" => candidate["label"].to_s.presence || candidate["local_label"].to_s.presence || name,
            "confidence" => candidate["confidence"].to_s
          }
        end
      end
      {
        "name" => name,
        "profile" => profile,
        "search_url" => authors_path(name: name)
      }.compact
    end

    payload = {
      "authors" => @author_values,
      "matches" => matches
    }
    log_author_link_payload(payload)
    payload
  end

  # A Corpus Viewer name becomes a direct profile link only when the resolver has
  # one defensible destination. Ambiguous identities go to Find Authors, where
  # all candidates and their evidence remain visible to the reader.
  def direct_candidate(candidates)
    rows = Array(candidates)
    high = rows.select { |candidate| candidate["confidence"].to_s == "high" }
    return high.first if high.length == 1
    return rows.first if rows.length == 1

    nil
  end

  def log_author_link_payload(payload)
    return unless Rails.env.development? || ENV["AUTHORITY_ANNOTATION_LOG"].to_s == "1"

    rows = Array(payload["matches"])
    summary = rows.map do |row|
      profile = row["profile"]
      if profile
        "#{row['name']}=>#{profile['source']}:#{profile['id']}"
      else
        "#{row['name']}=>search"
      end
    end
    Rails.logger.info("[authority] author links path=#{@source_path.inspect} #{summary.join(', ')}")
  rescue StandardError => e
    Rails.logger.debug("[authority] author-link diagnostic log skipped: #{e.class}: #{e.message}")
  end

  def render_index_error(message, status)
    if request.format.json?
      render json: { "error" => message, "authors" => [], "matches" => [] }, status: status
    else
      @author_error = message
      @candidate_set = HistoricalPersonRepository::CandidateSet.new(query_names: [], candidates: [], authority: {})
    end
  end

  def safe_find_candidates(names:, metadata:)
    @repository.find_candidates(names: names, metadata: metadata)
  rescue StandardError => e
    Rails.logger.warn("[authority] historical person lookup skipped: #{e.class}: #{e.message}")
    HistoricalPersonRepository::CandidateSet.new(query_names: Array(names), candidates: [], authority: {})
  end

  def corpus_people_for(names)
    queries = Array(names).map(&:to_s).map(&:strip).reject(&:empty?)
    return [] if queries.empty?

    index = CorpusCatalogueIndex.load
    queries.flat_map { |query| index.people_matching(query: query) }
      .uniq { |person| [person["name"], person["name_key"]] }
  rescue CorpusCatalogueIndex::CacheMissing
    []
  end

  def normalized_source_path(value)
    value.to_s.tr("\\", "/").sub(%r{\A/+}, "")
  end

  def metadata_for_path(path)
    return {} if path.blank?
    root = Rails.configuration.x.corpus_root
    fs = CorpusFs.new(root: root)
    absolute = fs.resolve(path)
    raise SecurityError, "Not a corpus path" unless fs.file?(absolute) || fs.directory?(absolute)

    store = CorpusMetadataStore.new(root: root, fs: fs)
    detailed = store.document_metadata_for_path(path)
    search = store.search_metadata_for_path(path)
    detailed.merge(search) { |_key, left, right| left.to_s.strip.empty? ? right : left }
  end

  def author_values(metadata)
    values = Array(metadata["authors"])
    values = [metadata["author"]] if values.empty? && metadata["author"].present?
    values.filter_map do |entry|
      case entry
      when Hash
        entry["name"].presence || entry["name_han"].presence || entry["label"].presence
      else
        entry.to_s.presence
      end
    end
  end
end
