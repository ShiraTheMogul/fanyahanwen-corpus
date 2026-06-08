# frozen_string_literal: true

require "set"
module CorpusSearch
  # Performs literal exact/proximity searches over canonical corpus files.
  #
  # It searches files, but it does not make the database the source of truth.
  class Runner
    DEFAULT_INTERACTIVE_LIMIT = 1_000

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
      paginated = hits[start_index, @query.per_page].to_a

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
          yield hit if block_given?
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

      ids_for_a = TermIndex.new(term: @query.term_a, manifest: @manifest, cache_store: @cache_store).doc_ids_with_hits.to_set
      docs = docs.select { |doc| ids_for_a.include?(doc["id"]) }

      if @query.proximity?
        ids_for_b = TermIndex.new(term: @query.term_b, manifest: @manifest, cache_store: @cache_store).doc_ids_with_hits.to_set
        docs = docs.select { |doc| ids_for_b.include?(doc["id"]) }
      end

      docs
    end

    def search_document(doc)
      raw = @fs.read_text(@fs.resolve(doc["path"]))
      _metadata, body = FrontMatter.split(raw)
      chars = SearchText.chars_for(body)

      if @query.proximity?
        proximity_hits(doc, body, chars)
      else
        exact_hits(doc, body, chars)
      end
    rescue Errno::ENOENT, SecurityError
      []
    end

    def exact_hits(doc, body, chars)
      term_length = @query.term_a.each_char.count

      SearchText.positions_of(chars, @query.term_a).map do |position|
        build_hit(doc, body, start_offset: position, end_offset: position + term_length)
      end
    end

    def proximity_hits(doc, body, chars)
      a_positions = SearchText.positions_of(chars, @query.term_a)
      b_positions = SearchText.positions_of(chars, @query.term_b)
      return [] if a_positions.empty? || b_positions.empty?

      a_length = @query.term_a.each_char.count
      b_length = @query.term_b.each_char.count
      hits = []
      seen = Set.new

      a_positions.each do |a_pos|
        b_positions.each do |b_pos|
          next unless allowed_order?(a_pos, b_pos)
          next if (a_pos - b_pos).abs > @query.distance

          start_offset = [a_pos, b_pos].min
          end_offset = [a_pos + a_length, b_pos + b_length].max
          key = [start_offset, end_offset]
          next if seen.include?(key)

          seen << key
          hits << build_hit(
            doc,
            body,
            start_offset: start_offset,
            end_offset: end_offset,
            term_a_offset: a_pos,
            term_b_offset: b_pos
          )
        end
      end

      hits
    end

    def allowed_order?(a_pos, b_pos)
      case @query.order
      when "a_before_b"
        a_pos <= b_pos
      when "b_before_a"
        b_pos <= a_pos
      else
        true
      end
    end

    def build_hit(doc, body, start_offset:, end_offset:, term_a_offset: nil, term_b_offset: nil)
      snippet = Snippet.build(
        body,
        start_offset: start_offset,
        end_offset: end_offset,
        context: @query.context
      )

      {
        "doc_id" => doc["id"],
        "path" => doc["path"],
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
        "term_a_offset" => term_a_offset,
        "term_b_offset" => term_b_offset,
        "left_context" => snippet["left_context"],
        "matched_text" => snippet["matched_text"],
        "right_context" => snippet["right_context"],
        "snippet" => snippet["snippet"]
      }
    end

    def sort_hits(hits)
      hits.sort_by { |hit| [hit["path"].to_s, hit["start_offset"].to_i, hit["end_offset"].to_i] }
    end
  end
end
