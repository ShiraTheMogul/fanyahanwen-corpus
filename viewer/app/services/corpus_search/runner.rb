# frozen_string_literal: true

require "set"

module CorpusSearch
  # Performs exact-sequence, alternative (OR), and multi-term proximity searches
  # over corpus bodies. Every body comes from DocumentReader, so metadata can
  # never produce a hit or enter a statistical denominator.
  class Runner
    DEFAULT_INTERACTIVE_LIMIT = 1_000
    MAX_CACHED_CONTEXT = 200
    MAX_INDEX_EQUIVALENTS = 12

    ScanResult = Data.define(:hits, :searchable_characters)
    AnalysisDocument = Data.define(:document, :hits, :searchable_characters)

    def initialize(query:, manifest: nil, cache_store: CacheStore.new)
      @query = query
      @cache_store = cache_store
      @manifest = manifest || Manifest.load(cache_store: @cache_store)
      @fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)
      @equivalence_registry = CharacterEquivalenceRegistry.new(level: @query.character_equivalence)
    end

    def page(max_hits: DEFAULT_INTERACTIVE_LIMIT)
      return empty_page unless @query.valid?

      docs = candidate_documents
      cache = QueryCache.new(query: @query, cache_store: @cache_store)
      cache.prune_to!(scoped_document_ids)

      hits = []
      scanned_files = 0
      complete = true

      docs.each do |doc|
        per_file_hits = cache.current_hits_for(doc)

        unless per_file_hits
          scan = scan_document(doc)
          per_file_hits = scan.hits
          cache.write_hits_for(doc, per_file_hits, searchable_characters: scan.searchable_characters)
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
      cache.prune_to!(scoped_document_ids)

      hit_count = 0
      docs.each_with_index do |doc, index|
        per_file_hits = cache.current_hits_for(doc)
        unless per_file_hits
          scan = scan_document(doc)
          per_file_hits = scan.hits
          cache.write_hits_for(doc, per_file_hits, searchable_characters: scan.searchable_characters)
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

    # Yields one compact, body-only statistical record per document in the
    # selected scope. Candidate indexes may prove that a document has zero hits,
    # but they must never remove that document from statistical denominators.
    # Cached hit lists and searchable-character counts are reused when present.
    def each_analysis_document(progress: nil)
      return 0 unless @query.valid?

      docs = scoped_documents
      candidate_ids = candidate_documents.map { |doc| doc["id"] }.to_set
      cache = QueryCache.new(query: @query, cache_store: @cache_store)
      cache.prune_to!(scoped_document_ids)

      docs.each_with_index do |doc, index|
        hits = cache.current_hits_for(doc)
        searchable_characters = cache.current_searchable_characters_for(doc)

        if candidate_ids.include?(doc["id"])
          if hits.nil?
            scan = scan_document(doc)
            hits = scan.hits
            searchable_characters = scan.searchable_characters
            cache.write_hits_for(doc, hits, searchable_characters: searchable_characters)
          elsif searchable_characters.nil?
            searchable_characters = searchable_character_count(doc)
            cache.write_searchable_characters_for(doc, searchable_characters)
          end
        else
          # A received-text term index is only used when it supplies a safe
          # necessary condition. Missing the anchor therefore proves zero hits,
          # while the body length is still required for rates and prevalence.
          hits = []
          searchable_characters = searchable_character_count(doc) if searchable_characters.nil?
        end

        yield AnalysisDocument.new(
          document: doc,
          hits: sort_hits(hits),
          searchable_characters: searchable_characters.to_i
        ) if block_given?

        progress&.call(index + 1, docs.length)
        cache.save! if (index + 1) % 25 == 0
      end

      cache.save!
      docs.length
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

    def scoped_documents
      @scoped_documents ||= @manifest.filtered(@query.filters)
    end

    def scoped_document_ids
      @scoped_document_ids ||= scoped_documents.map { |doc| doc["id"] }
    end

    def candidate_documents
      docs = scoped_documents
      canonical_docs = docs.select { |doc| DocumentRole.default?(doc["document_role"].presence || "canonical") }
      return docs if canonical_docs.empty?

      anchor_classes = index_anchor_classes
      return docs if anchor_classes.empty?
      return docs if @query.alternatives? && anchor_classes.length < query_patterns.length

      # Broad/common matching may require several literal indexes for one query
      # character. Warm all selected forms in one corpus pass, then union forms
      # within a term. Required terms are intersected; OR alternatives are unioned.
      literal_terms = anchor_classes.flat_map(&:to_a).uniq
      TermIndex.refresh_single_character_terms!(
        terms: literal_terms,
        manifest: @manifest,
        cache_store: @cache_store
      )

      anchor_id_sets = anchor_classes.map do |forms|
        forms.each_with_object(Set.new) do |form, union|
          union.merge(
            TermIndex.new(term: form, manifest: @manifest, cache_store: @cache_store).doc_ids_with_hits
          )
        end
      end

      indexed_ids = if @query.alternatives?
        anchor_id_sets.each_with_object(Set.new) { |ids, union| union.merge(ids) }
      else
        canonical_docs.map { |doc| doc["id"] }.to_set.tap do |intersection|
          anchor_id_sets.each do |ids|
            intersection &= ids
            break if intersection.empty?
          end
        end
      end

      # The term index deliberately covers received texts only. When a user also
      # selects variants, raw scrapes, translations, or annotations, retain those
      # documents for direct scanning while narrowing the larger received layer.
      docs.select do |doc|
        role = doc["document_role"].presence || "canonical"
        !DocumentRole.default?(role) || indexed_ids.include?(doc["id"])
      end
    end

    # Select one necessary character class from each query term. Prefer a
    # substantive character with the smallest controlled equivalence class.
    # Very large classes are intentionally not indexed: direct scanning is safer
    # than creating dozens of whole-corpus indexes for one ambiguous character.
    def index_anchor_classes
      profile = NormalizationProfile.current

      query_patterns.filter_map do |pattern|
        candidates = pattern.query_units.each_with_index.reject do |character, _index|
          profile.ignored?(character)
        end
        candidates = pattern.query_units.each_with_index.to_a if candidates.empty?

        eligible = candidates.filter_map do |_character, index|
          forms = pattern.allowed_units.fetch(index)
          next if forms.empty? || forms.length > MAX_INDEX_EQUIVALENTS

          forms
        end

        eligible.min_by(&:length)
      end
    end

    def query_patterns
      @query_patterns ||= @query.effective_terms.map do |term|
        CharacterPattern.build(
          term,
          punctuation: @query.punctuation,
          registry: @equivalence_registry
        )
      end
    end

    def scan_document(doc)
      document = DocumentReader.read(fs: @fs, path: doc["path"])
      body = document.body
      searchable = NormalizedText.build(body, punctuation: @query.punctuation)
      hits = search_loaded_document(doc, body, searchable)
      ScanResult.new(hits: hits, searchable_characters: searchable.units.length)
    rescue Errno::ENOENT, SecurityError
      ScanResult.new(hits: [], searchable_characters: 0)
    end

    def searchable_character_count(doc)
      document = DocumentReader.read(fs: @fs, path: doc["path"])
      NormalizedText.build(document.body, punctuation: @query.punctuation).units.length
    rescue Errno::ENOENT, SecurityError
      0
    end

    def search_loaded_document(doc, body, searchable)
      if @query.proximity?
        proximity_hits(doc, body, searchable)
      elsif @query.alternatives?
        alternative_hits(doc, body, searchable)
      else
        exact_hits(doc, body, searchable)
      end
    end

    def exact_hits(doc, body, searchable)
      pattern = query_patterns.first
      return [] if pattern.nil? || pattern.empty?

      pattern.positions_in(searchable.units).filter_map do |search_position|
        original_range = searchable.original_range(search_position, search_position + pattern.length)
        next unless original_range

        equivalence_matches = pattern.equivalence_matches_at(
          searchable: searchable,
          search_start: search_position
        )

        build_hit(
          doc,
          body,
          start_offset: original_range[0],
          end_offset: original_range[1],
          search_start_offset: search_position,
          search_end_offset: search_position + pattern.length,
          equivalence_matches: equivalence_matches
        )
      end
    end

    def alternative_hits(doc, body, searchable)
      matches_by_range = {}

      query_patterns.each_with_index do |pattern, term_index|
        next if pattern.empty?

        pattern.positions_in(searchable.units).each do |search_position|
          search_end = search_position + pattern.length
          original_range = searchable.original_range(search_position, search_end)
          next unless original_range

          equivalence_matches = pattern.equivalence_matches_at(
            searchable: searchable,
            search_start: search_position,
            term_index: term_index
          )
          term_match = {
            "term_index" => term_index,
            "term" => @query.terms.fetch(term_index),
            "start_offset" => original_range[0],
            "end_offset" => original_range[1],
            "search_start_offset" => search_position,
            "search_end_offset" => search_end,
            "equivalence_matches" => equivalence_matches
          }

          key = [original_range[0], original_range[1], search_position, search_end]
          entry = matches_by_range[key] ||= {
            original_range: original_range,
            search_start: search_position,
            search_end: search_end,
            term_matches: [],
            equivalence_matches: []
          }
          entry[:term_matches] << term_match unless entry[:term_matches].any? { |existing| existing["term_index"] == term_index }
          entry[:equivalence_matches].concat(equivalence_matches)
        end
      end

      matches_by_range.values.map do |entry|
        build_hit(
          doc,
          body,
          start_offset: entry[:original_range][0],
          end_offset: entry[:original_range][1],
          search_start_offset: entry[:search_start],
          search_end_offset: entry[:search_end],
          term_matches: entry[:term_matches].sort_by { |match| match["term_index"] },
          equivalence_matches: entry[:equivalence_matches]
        )
      end
    end

    def proximity_hits(doc, body, searchable)
      patterns = query_patterns
      return [] if patterns.any?(&:empty?)

      matches = ProximityMatcher.new(
        searchable_units: searchable.units,
        term_patterns: patterns.map(&:allowed_units),
        maximum_span: @query.maximum_span,
        order: @query.order
      ).matches

      matches.filter_map do |match|
        original_range = searchable.original_range(match.search_start, match.search_end)
        next unless original_range

        equivalence_matches = []
        term_matches = match.term_matches.filter_map do |term_match|
          term_original_range = searchable.original_range(term_match.search_start, term_match.search_end)
          next unless term_original_range

          term_equivalence_matches = patterns.fetch(term_match.term_index).equivalence_matches_at(
            searchable: searchable,
            search_start: term_match.search_start,
            term_index: term_match.term_index
          )
          equivalence_matches.concat(term_equivalence_matches)

          {
            "term_index" => term_match.term_index,
            "term" => @query.terms.fetch(term_match.term_index),
            "start_offset" => term_original_range[0],
            "end_offset" => term_original_range[1],
            "search_start_offset" => term_match.search_start,
            "search_end_offset" => term_match.search_end,
            "equivalence_matches" => term_equivalence_matches
          }
        end
        next unless term_matches.length == @query.terms.length

        build_hit(
          doc,
          body,
          start_offset: original_range[0],
          end_offset: original_range[1],
          search_start_offset: match.search_start,
          search_end_offset: match.search_end,
          term_matches: term_matches,
          equivalence_matches: equivalence_matches
        )
      end
    end

    def build_hit(doc, body, start_offset:, end_offset:, search_start_offset:, search_end_offset:,
                  term_matches: nil, equivalence_matches: nil)
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
        "term_matches" => Array(term_matches),
        "character_equivalence" => @query.character_equivalence,
        "character_equivalence_version" => @query.character_equivalence_version,
        "equivalence_matches" => Array(equivalence_matches),
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
