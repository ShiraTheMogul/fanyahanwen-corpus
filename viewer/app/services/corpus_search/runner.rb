# frozen_string_literal: true

require "set"

module CorpusSearch
  # Performs exact-sequence, alternative (OR), and multi-term proximity searches
  # over corpus bodies. Every body comes from DocumentReader, so metadata can
  # never produce a hit or enter a statistical denominator.
  class Runner
    DEFAULT_INTERACTIVE_LIMIT = 1_000
    DEFAULT_INTERACTIVE_SCAN_LIMIT = 5_000
    MAX_CACHED_CONTEXT = 200
    MAX_INDEX_EQUIVALENTS = 12
    DEFAULT_DIRECT_SCAN_SCOPE_LIMIT = 5_000
    DEFAULT_CACHE_CHECKPOINT_EVERY = 10_000

    ScanResult = Data.define(:hits, :searchable_characters, :body_fingerprint)
    DocumentStats = Data.define(:searchable_characters, :body_fingerprint)
    AnalysisDocument = Data.define(:document, :hits, :searchable_characters, :body_fingerprint)

    def initialize(query:, manifest: nil, cache_store: CacheStore.new)
      @query = query
      @cache_store = cache_store
      @manifest = manifest || Manifest.load(cache_store: @cache_store)
      @fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)
      @equivalence_registry = CharacterEquivalenceRegistry.new(level: @query.character_equivalence)
    end

    def page(max_hits: DEFAULT_INTERACTIVE_LIMIT, max_scans: interactive_scan_limit)
      return empty_page unless @query.valid?

      docs = candidate_documents
      cache = QueryCache.new(query: @query, cache_store: @cache_store)
      hits = []
      scanned_files = 0
      complete = true

      docs.each_with_index do |doc, index|
        per_file_hits = cache.current_hits_for(doc)

        unless per_file_hits
          if max_scans && max_scans.positive? && scanned_files >= max_scans
            complete = false
            break
          end

          scan = scan_document(doc)
          per_file_hits = scan.hits
          cache.write_hits_for(
            doc,
            per_file_hits,
            searchable_characters: scan.searchable_characters,
            body_fingerprint: scan.body_fingerprint
          )
          scanned_files += 1
        end

        hits.concat(per_file_hits)

        if max_hits && hits.length >= max_hits
          complete = false
          hits = hits.first(max_hits)
          break
        end

      end

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
    ensure
      cache&.close
      close_document_stats_cache
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
      hit_count = 0

      docs.each_with_index do |doc, index|
        per_file_hits = cache.current_hits_for(doc)
        unless per_file_hits
          scan = scan_document(doc)
          per_file_hits = scan.hits
          cache.write_hits_for(
            doc,
            per_file_hits,
            searchable_characters: scan.searchable_characters,
            body_fingerprint: scan.body_fingerprint
          )
        end

        sort_hits(per_file_hits).each do |hit|
          hit_count += 1
          yield present_hit(hit) if block_given?
        end

        progress&.call(index + 1, docs.length, hit_count)
        if checkpoint_due?(index + 1)
          cache.save!
          @document_stats_cache&.save!
        end
      end

      hit_count
    ensure
      cache&.close
      close_document_stats_cache
    end

    # Yields one compact, body-only statistical record per document in the
    # selected scope. Candidate indexes may prove that a document has zero hits,
    # but they must never remove that document from statistical denominators.
    # Cached hit lists and searchable-character counts are reused when present.
    def each_analysis_document(progress: nil)
      return 0 unless @query.valid?

      docs = scoped_documents
      candidates = candidate_documents
      all_documents_are_candidates = candidates.equal?(docs)
      candidate_ids = candidates.map { |doc| doc["id"] }.to_set unless all_documents_are_candidates
      cache = QueryCache.new(query: @query, cache_store: @cache_store)

      docs.each_with_index do |doc, index|
        cached_record = cache.current_record_for(doc)
        hits = cached_record&.hits
        searchable_characters = cached_record&.searchable_characters
        body_fingerprint = cached_record&.body_fingerprint

        if all_documents_are_candidates || candidate_ids.include?(doc["id"])
          if hits.nil?
            scan = scan_document(doc)
            hits = scan.hits
            searchable_characters = scan.searchable_characters
            body_fingerprint = scan.body_fingerprint
            cache.write_hits_for(
              doc,
              hits,
              searchable_characters: searchable_characters,
              body_fingerprint: body_fingerprint
            )
          elsif searchable_characters.nil? || body_fingerprint.nil?
            stats = document_stats(doc)
            searchable_characters = stats.searchable_characters
            body_fingerprint = stats.body_fingerprint
            cache.write_document_stats_for(
              doc,
              searchable_characters: searchable_characters,
              body_fingerprint: body_fingerprint
            )
          end
        else
          # A received-text term index is only used when it supplies a safe
          # necessary condition. Missing the anchor therefore proves zero hits,
          # while the body length is still required for rates and prevalence.
          hits = []
          if searchable_characters.nil? || body_fingerprint.nil?
            stats = document_stats(doc)
            searchable_characters = stats.searchable_characters
            body_fingerprint = stats.body_fingerprint
            cache.write_document_stats_for(
              doc,
              searchable_characters: searchable_characters,
              body_fingerprint: body_fingerprint,
              hits: []
            )
          end
        end

        yield AnalysisDocument.new(
          document: doc,
          hits: sort_hits(hits),
          searchable_characters: searchable_characters.to_i,
          body_fingerprint: body_fingerprint.to_s
        ) if block_given?

        progress&.call(index + 1, docs.length)
        if checkpoint_due?(index + 1)
          cache.save!
          @document_stats_cache&.save!
        end
      end

      docs.length
    ensure
      cache&.close
      close_document_stats_cache
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

    def candidate_documents
      return @candidate_documents if defined?(@candidate_documents)

      docs = scoped_documents

      # A bounded scope is cheaper to read directly than a global index is to
      # decompress and parse. The audit found a 40-document scope spending nearly
      # forty minutes opening corpus-wide indexes under WSL/OneDrive.
      return @candidate_documents = docs if direct_scan_scope?(docs)

      anchor_classes = index_anchor_classes
      return @candidate_documents = fallback_scan_documents(docs) if anchor_classes.empty?
      return @candidate_documents = fallback_scan_documents(docs) if @query.alternatives? && anchor_classes.length < query_patterns.length

      # Search requests never build a whole-corpus index synchronously. Existing
      # current indexes are reused; missing or stale indexes fall back to a direct
      # scan. Explicit rake warming remains responsible for expensive index builds.
      literal_terms = anchor_classes.flat_map(&:to_a).uniq
      indexed_doc_ids = TermIndex.current_doc_ids_for_terms(
        terms: literal_terms,
        manifest: @manifest,
        cache_store: @cache_store
      )
      return @candidate_documents = fallback_scan_documents(docs) unless indexed_doc_ids

      canonical_docs = docs.select { |doc| DocumentRole.default?(doc["document_role"].presence || "canonical") }
      return @candidate_documents = fallback_scan_documents(docs) if canonical_docs.empty?

      anchor_id_sets = anchor_classes.map do |forms|
        forms.each_with_object(Set.new) do |form, union|
          union.merge(indexed_doc_ids.fetch(form, []))
        end
      end

      indexed_ids = if @query.alternatives?
        anchor_id_sets.each_with_object(Set.new) { |ids, union| union.merge(ids) }
      else
        intersection = canonical_docs.map { |doc| doc["id"] }.to_set
        anchor_id_sets.each do |ids|
          intersection &= ids
          break if intersection.empty?
        end
        intersection
      end

      # The term index deliberately covers received texts only. When a user also
      # selects variants, raw scrapes, translations, or annotations, retain those
      # documents for direct scanning while narrowing the larger received layer.
      @candidate_documents = docs.select do |doc|
        role = doc["document_role"].presence || "canonical"
        !DocumentRole.default?(role) || indexed_ids.include?(doc["id"])
      end
    end

    # When no current term index exists, do not present the first arbitrary
    # filesystem slice as though it were representative. Cached body signatures
    # and path/title hints only change ordering; every document remains eligible
    # for eventual scanning, so correctness is unchanged.
    def fallback_scan_documents(docs)
      cached_ids = document_stats_cache.matching_document_ids(
        term_patterns: query_patterns.map(&:allowed_units),
        alternatives: @query.alternatives?
      )
      hints = metadata_search_hints
      prioritised = []
      prioritised_ids = Set.new

      docs.each_with_index do |doc, index|
        score = metadata_priority_score(doc, hints)
        score += 10_000 if cached_ids.include?(doc["id"].to_s)
        next unless score.positive?

        prioritised << [score, index, doc]
        prioritised_ids << doc["id"].to_s
      end

      return docs if prioritised.empty?

      prioritised.sort_by! { |score, index, _doc| [-score, index] }
      prioritised.map!(&:last)
      prioritised.concat(docs.reject { |doc| prioritised_ids.include?(doc["id"].to_s) })
    end

    def metadata_search_hints
      @metadata_search_hints ||= begin
        phrases = query_patterns.map { |pattern| pattern.query_units.join }
        if @query.proximity? && @query.order == "entered"
          joined = phrases.join
          phrases << joined if joined.each_char.count >= 2
        end

        phrases.flat_map do |phrase|
          chars = phrase.each_char.to_a
          next [] if chars.length < 2

          hints = [phrase]
          [4, 3, 2].each do |length|
            next if chars.length < length

            chars.each_cons(length) { |slice| hints << slice.join }
          end
          hints
        end.uniq.sort_by { |hint| -hint.each_char.count }
      end
    end

    def metadata_priority_score(doc, hints)
      return 0 if hints.empty?

      title = doc["title"].to_s
      work = doc["work"].to_s
      path = doc["path"].to_s
      hints.sum do |hint|
        length = hint.each_char.count
        score = 0
        score += 500 + (length * 20) if title.include?(hint)
        score += 300 + (length * 15) if work.include?(hint)
        score += 100 + (length * 10) if path.include?(hint)
        score
      end
    end

    def interactive_scan_limit
      value = Integer(ENV.fetch("CORPUS_SEARCH_INTERACTIVE_SCAN_LIMIT", DEFAULT_INTERACTIVE_SCAN_LIMIT.to_s))
      value.positive? ? value : nil
    rescue ArgumentError, TypeError
      DEFAULT_INTERACTIVE_SCAN_LIMIT
    end

    def direct_scan_scope?(docs)
      limit = Integer(ENV.fetch("CORPUS_SEARCH_DIRECT_SCAN_LIMIT", DEFAULT_DIRECT_SCAN_SCOPE_LIMIT.to_s))
      limit.positive? && docs.length <= limit
    rescue ArgumentError, TypeError
      docs.length <= DEFAULT_DIRECT_SCAN_SCOPE_LIMIT
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

        eligible.min_by do |forms|
          indexes_present = forms.all? do |form|
            @cache_store.exist?(TermIndex.cache_path_for(form))
          end
          known_frequency = forms.sum do |form|
            frequency_counts.fetch(form, 1 << 60)
          end

          [indexes_present ? 0 : 1, known_frequency, forms.length]
        end
      end
    end

    def frequency_counts
      @frequency_counts ||= FrequencySnapshot.counts(cache_store: @cache_store)
    end

    def close_document_stats_cache
      @document_stats_cache&.close
      @document_stats_cache = nil
    end

    def checkpoint_due?(position)
      every = Integer(ENV.fetch("CORPUS_SEARCH_CACHE_CHECKPOINT_EVERY", DEFAULT_CACHE_CHECKPOINT_EVERY.to_s))
      every.positive? && (position % every).zero?
    rescue ArgumentError, TypeError
      (position % DEFAULT_CACHE_CHECKPOINT_EVERY).zero?
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
      searchable_characters = searchable.units.length
      document_stats_cache.write(
        doc,
        punctuation: @query.punctuation,
        searchable_characters: searchable_characters,
        body_fingerprint: document.body_fingerprint,
        character_bloom: CharacterBloom.build(body)
      )
      hits = search_loaded_document(doc, body, searchable)
      ScanResult.new(
        hits: hits,
        searchable_characters: searchable_characters,
        body_fingerprint: document.body_fingerprint
      )
    rescue Errno::ENOENT, SecurityError
      ScanResult.new(hits: [], searchable_characters: 0, body_fingerprint: nil)
    end

    def document_stats(doc)
      cached = document_stats_cache.fetch(doc, punctuation: @query.punctuation)
      if cached
        return DocumentStats.new(
          searchable_characters: cached.searchable_characters,
          body_fingerprint: cached.body_fingerprint
        )
      end

      document = DocumentReader.read(fs: @fs, path: doc["path"])
      searchable_characters = NormalizedText.build(
        document.body,
        punctuation: @query.punctuation
      ).units.length
      document_stats_cache.write(
        doc,
        punctuation: @query.punctuation,
        searchable_characters: searchable_characters,
        body_fingerprint: document.body_fingerprint,
        character_bloom: CharacterBloom.build(document.body)
      )
      DocumentStats.new(
        searchable_characters: searchable_characters,
        body_fingerprint: document.body_fingerprint
      )
    rescue Errno::ENOENT, SecurityError
      DocumentStats.new(searchable_characters: 0, body_fingerprint: nil)
    end

    def document_stats_cache
      @document_stats_cache ||= DocumentStatsCache.new(cache_store: @cache_store)
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
