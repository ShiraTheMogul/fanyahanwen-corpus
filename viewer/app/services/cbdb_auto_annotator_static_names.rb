# frozen_string_literal: true

# Automatic historical annotation uses the small authority orthography registry.
# It also treats the CBDB and supplementary historical indexes as independent
# sources: one malformed or temporarily unavailable source must not disable the
# other source for the whole reader.
module CbdbAutoAnnotatorStaticNames
  MAX_PREFIX_FORMS = 16

  def initialize(text:, metadata:, store:)
    @text = text.to_s
    @chars = @text.each_char.to_a
    @metadata = metadata.to_h.stringify_keys
    @store = normalize_store(store)
    @equivalence = AuthorityHanVariantRegistry.instance
    @prefix_cache = {}
  end

  def call
    @context = temporal_context
    authority = safe_authority_metadata
    return CbdbAutoAnnotator::Result.new(items: [], context: @context, authority: authority) unless @store.available?

    matches = []
    source_attempts = 0
    source_successes = 0
    failures = []

    @store.with_database do |db|
      @db = db
      prefixes = text_prefixes

      if @store.lookup_available? && prefixes.any?
        source_attempts += 1
        begin
          matches.concat(cbdb_matches(prefixes))
          source_successes += 1
        rescue StandardError => e
          failures << ["cbdb", e]
          log_source_failure("CBDB", e)
        end
      end

      if @store.historical_available?
        source_attempts += 1
        begin
          matches.concat(historical_matches(prefixes)) if prefixes.any?
          matches.concat(single_character_diviner_matches)
          source_successes += 1
        rescue StandardError => e
          failures << ["historical", e]
          log_source_failure("historical", e)
        end
      end
    ensure
      @db = nil
    end

    if source_attempts.positive? && source_successes.zero? && failures.any?
      raise failures.first.last
    end

    authority = safe_authority_metadata.merge(
      "annotation_partial" => failures.any?,
      "annotation_failed_sources" => failures.map(&:first)
    )
    CbdbAutoAnnotator::Result.new(
      items: resolve_overlaps(matches).map { |match| public_item(match) },
      context: @context,
      authority: authority
    )
  end

  private

  def cbdb_matches(prefixes)
    rows = fetch_pointer_rows("cbdb_lookup", prefixes)
    hydrated = []
    rows.group_by { |row| row["kind"].to_s }.each do |kind, kind_rows|
      begin
        hydrated.concat(hydrate_cbdb(kind_rows))
      rescue StandardError => e
        log_source_failure("CBDB #{kind}", e)
      end
    end
    build_multi_matches(hydrated)
  end

  # The text can contain thousands of unique bigrams. Expanding every character
  # into a 12×12 Cartesian product creates a large transient query vocabulary.
  # Keep the literal form, each one-character substitution, and a small number
  # of combined substitutions. Historical names already store derived OpenCC
  # spellings, so this remains tolerant without exploding the request path.
  def equivalent_prefixes(prefix)
    @prefix_cache[prefix] ||= begin
      chars = prefix.each_char.to_a
      if chars.length != 2
        [prefix]
      else
        left = @equivalence.forms_for(chars[0]).to_a.sort
        right = @equivalence.forms_for(chars[1]).to_a.sort
        forms = [prefix]
        left.each { |form| forms << (form + chars[1]) unless form == chars[0] }
        right.each { |form| forms << (chars[0] + form) unless form == chars[1] }
        left.product(right).each do |a, b|
          combined = a + b
          forms << combined unless combined == prefix
          break if forms.length >= MAX_PREFIX_FORMS
        end
        forms.uniq.first(MAX_PREFIX_FORMS)
      end
    end
  end

  def safe_authority_metadata
    @store.metadata.to_h.stringify_keys
  rescue StandardError => e
    log_source_failure("metadata", e)
    {}
  end

  def log_source_failure(source, error)
    return unless defined?(Rails) && Rails.respond_to?(:logger)

    Rails.logger&.warn("[authority] #{source} automatic annotation source failed: #{error.class}: #{error.message}")
  end
end
