# frozen_string_literal: true

require "set"

module CorpusSearch
  # Performs exact-sequence and two-term proximity searches over corpus bodies.
  # Every body comes from DocumentReader, so metadata can never produce a hit.
  class Runner
    DEFAULT_INTERACTIVE_LIMIT = 1_000
    MAX_CACHED_CONTEXT = 200

    def initialize(query:, manifest: nil, cache_store: CacheStore.new)
      @query = query
      @cache_store = cache_store
      @manifest = manifest || Manifest.load(cache_store: @cache_store)
      @fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)
    end

    def page(max_hits: DEFAULT_INTERACTIVE_LIMIT)
      return empty_page unless @query.valid?

      docs = candidate_documents
      cache = QueryCache.new(query: @query, cache_store: @cache_store)
      cache.prune_to!(docs.map { |doc| doc["id"] })

      hits = []
      scanned_files = 0
      complete = true

      docs.each do |doc|
        per_file_hits = cache.current_hits_for(doc)

        unless per_file_hits
          per_file_hits = search_document(doc)
          cache.write_hits_for(doc, per_file_hits)
          scanned_files += 1
        end

        hits.concat(per_file_hits)

        if max_hits && hits.length >= max_hits
          complete = false
          hits = hits.first(max_hits)
          break
        end
      end

      cache.save!
      hits = sort_hits(hits)
      total = hits.length
      start_index = (@query.page - 1) * @query.per_page
      paginated = hits[start_index, @query.per_page].to_a.map { |hit| present_hit(hit) }

      ResultPage.new(
        query: @query,
        hits: paginated,
        page: @query.page,
        per_page: @query.per_page,
        total: total,
        complete: complete,
        truncated: !complete,
        scanned_files: scanned_files,
        candidate_files: docs.length
      )
    end

    def all_hits(progress: nil)
      hits = []
      each_hit(progress: progress) { |hit| hits << hit }
      sort_hits(hits)
    end

    def each_hit(progress: nil)
      return 0 unless @query.valid?

      docs = candidate_documents
      cache = QueryCache.new(query: @query, cache_store: @cache_store)
      cache.prune_to!(docs.map { |doc| doc["id"] })

      hit_count = 0
      docs.each_with_index do |doc, index|
        per_file_hits = cache.current_hits_for(doc)
        unless per_file_hits
          per_file_hits = search_document(doc)
          cache.write_hits_for(doc, per_file_hits)
        end

        sort_hits(per_file_hits).each do |hit|
          hit_count += 1
          yield present_hit(hit) if block_given?
        end

        progress&.call(index + 1, docs.length, hit_count)
        cache.save! if (index + 1) % 25 == 0
      end

      cache.save!
      hit_count
    end

    private

    def empty_page
      ResultPage.new(
        query: @query,
        hits: [],
        page: @query.page,
        per_page: @query.per_page,
        total: 0,
        complete: true,
        truncated: false,
        scanned_files: 0,
        candidate_files: 0
      )
    end

    def candidate_documents
      docs = @manifest.filtered(@query.filters)
      canonical_docs = docs.select { |doc| DocumentRole.default?(doc["document_role"].presence || "canonical") }
      return docs if canonical_docs.empty?

      indexed_ids = canonical_docs.map { |doc| doc["id"] }.to_set
      index_anchors.each do |anchor|
        anchor_ids = TermIndex.new(term: anchor, manifest: @manifest, cache_store: @cache_store).doc_ids_with_hits.to_set
        indexed_ids &= anchor_ids
        break if indexed_ids.empty?
      end

      # The term index deliberately covers canonical texts only. When a user also
      # selects variants, raw scrapes, translations, or annotations, retain those
      # documents for direct scanning while still narrowing the much larger
      # canonical layer through the index.
      docs.select do |doc|
        role = doc["document_role"].presence || "canonical"
        !DocumentRole.default?(role) || indexed_ids.include?(doc["id"])
      end
    end

    # Arbitrary phrases should not create a permanent whole-corpus term index for
    # every wording a visitor tries. Use one necessary character from each term as
    # a broad candidate anchor, then verify the complete phrase in the document.
    # Prefer a substantive character when punctuation is being respected.
    def index_anchors
      profile = NormalizationProfile.current

      @query.effective_terms.filter_map do |term|
        normalized = NormalizedText.build(term, punctuation: @query.punctuation, profile: profile)
        next if normalized.empty?

        normalized.units.find { |character| !profile.ignored?(character) } || normalized.units.first
      end.uniq
    end

    def search_document(doc)
      document = DocumentReader.read(fs: @fs, path: doc["path"])
      body = document.body
      searchable = NormalizedText.build(body, punctuation: @query.punctuation)

      if @query.proximity?
        proximity_hits(doc, body, searchable)
      else
        exact_hits(doc, body, searchable)
      end
    rescue Errno::ENOENT, SecurityError
      []
    end

    def exact_hits(doc, body, searchable)
      query_stream = NormalizedText.build(@query.query_text, punctuation: @query.punctuation)
      term_length = query_stream.units.length
      return [] if term_length.zero?

      SearchText.positions_of(searchable.units, query_stream.units).filter_map do |search_position|
        original_range = searchable.original_range(search_position, search_position + term_length)
        next unless original_range

        build_hit(
          doc,
          body,
          start_offset: original_range[0],
          end_offset: original_range[1],
          search_start_offset: search_position,
          search_end_offset: search_position + term_length
        )
      end
    end

    def proximity_hits(doc, body, searchable)
      first_stream = NormalizedText.build(@query.terms[0], punctuation: @query.punctuation)
      second_stream = NormalizedText.build(@query.terms[1], punctuation: @query.punctuation)
      return [] if first_stream.empty? || second_stream.empty?

      first_positions = SearchText.positions_of(searchable.units, first_stream.units)
      second_positions = SearchText.positions_of(searchable.units, second_stream.units)
      return [] if first_positions.empty? || second_positions.empty?

      hits = []
      seen = Set.new

      first_positions.each do |first_position|
        second_positions.each do |second_position|
          next if repeated_term_same_occurrence?(first_stream, second_stream, first_position, second_position)
          next unless allowed_order?(first_position, second_position)

          search_start = [first_position, second_position].min
          search_end = [first_position + first_stream.units.length, second_position + second_stream.units.length].max
          next if search_end - search_start > @query.maximum_span

          original_range = searchable.original_range(search_start, search_end)
          first_original = searchable.original_range(first_position, first_position + first_stream.units.length)
          second_original = searchable.original_range(second_position, second_position + second_stream.units.length)
          next unless original_range && first_original && second_original

          key = [original_range[0], original_range[1], first_original[0], second_original[0]]
          next if seen.include?(key)

          seen << key
          hits << build_hit(
            doc,
            body,
            start_offset: original_range[0],
            end_offset: original_range[1],
            search_start_offset: search_start,
            search_end_offset: search_end,
            term_a_offset: first_original[0],
            term_b_offset: second_original[0]
          )
        end
      end

      hits
    end

    def repeated_term_same_occurrence?(first_stream, second_stream, first_position, second_position)
      first_stream.units == second_stream.units && first_position == second_position
    end

    def allowed_order?(first_position, second_position)
      @query.order == "any" || first_position <= second_position
    end

    def build_hit(doc, body, start_offset:, end_offset:, search_start_offset:, search_end_offset:,
                  term_a_offset: nil, term_b_offset: nil)
      snippet = Snippet.build(
        body,
        start_offset: start_offset,
        end_offset: end_offset,
        context: MAX_CACHED_CONTEXT
      )

      {
        "doc_id" => doc["id"],
        "path" => doc["path"],
        "folder_path" => doc["folder_path"].to_s,
        "document_role" => doc["document_role"].presence || "canonical",
        "canonical_parent_path" => doc["canonical_parent_path"],
        "title" => doc["title"].to_s,
        "work" => doc["work"].to_s,
        "author" => doc["author"].to_s,
        "date_text" => doc["date_text"].to_s,
        "year_start" => doc["year_start"],
        "year_end" => doc["year_end"],
        "nation" => doc["nation"].to_s,
        "period" => doc["period"].to_s,
        "region" => doc["region"].to_s,
        "start_offset" => start_offset,
        "end_offset" => end_offset,
        "search_start_offset" => search_start_offset,
        "search_end_offset" => search_end_offset,
        "term_a_offset" => term_a_offset,
        "term_b_offset" => term_b_offset,
        "punctuation" => @query.punctuation,
        "normalization_profile_version" => @query.normalization_profile_version,
        "left_context" => snippet["left_context"],
        "matched_text" => snippet["matched_text"],
        "right_context" => snippet["right_context"],
        "snippet" => snippet["snippet"]
      }
    end

    def present_hit(hit)
      context = @query.context
      left_chars = hit["left_context"].to_s.each_char.to_a
      right_chars = hit["right_context"].to_s.each_char.to_a
      left = context.zero? ? "" : left_chars.last(context).to_a.join
      right = context.zero? ? "" : right_chars.first(context).to_a.join

      hit.merge(
        "left_context" => left,
        "right_context" => right,
        "snippet" => [left, hit["matched_text"].to_s, right].join
      )
    end

    def sort_hits(hits)
      hits.sort_by { |hit| [hit["path"].to_s, hit["start_offset"].to_i, hit["end_offset"].to_i] }
    end
  end
end
