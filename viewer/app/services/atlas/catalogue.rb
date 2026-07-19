# frozen_string_literal: true

require "json"
require "pathname"
require "thread"

module Atlas
  # Read-only runtime catalogue prepared by Atlas::CatalogueBuilder.
  #
  # Web requests load one compact JSON payload. They never traverse the corpus,
  # glob metadata files, or validate the full atlas tree. In development, the
  # payload is reloaded only when the generated file's mtime or size changes.
  class Catalogue
    VERSION = 2
    CACHE_PATH = "atlas/catalogue-v2.json.gz"
    DEVELOPMENT_RELOAD_INTERVAL = 1.0

    class Missing < StandardError; end
    class Invalid < StandardError; end

    def self.default
      @default ||= new
    end

    def self.reset!
      @default = nil
    end

    attr_reader :cache_store

    def initialize(cache_store: CorpusSearch::CacheStore.new)
      @cache_store = cache_store
      @mutex = Mutex.new
      @signature = nil
      @next_reload_check_at = 0.0
      @payload = nil
      @entries = nil
      @entries_by_id = nil
      @aliases = nil
    end

    def generated_at = payload["generated_at"].to_s
    def manifest_generated_at = payload["manifest_generated_at"].to_s
    def source = payload["source"].to_s

    def entries
      ensure_loaded!
      @entries
    end

    def find(id)
      ensure_loaded!
      key = id.to_s
      @entries_by_id[key] || @entries_by_id[@aliases[key]]
    end

    def find!(id)
      find(id) || raise(ActiveRecord::RecordNotFound, "Unknown atlas entry")
    end

    def macro_regions
      payload.fetch("macro_regions")
    end

    def macro_region(id)
      macro_regions_by_id[id.to_s]
    end

    def macro_region!(id)
      macro_region(id) || raise(ActiveRecord::RecordNotFound, "Unknown atlas macro-region")
    end

    def macro_region_for_root(corpus_root)
      payload.fetch("indexes").fetch("macro_region_by_corpus_root", {})[corpus_root.to_s]
    end

    def periods_for(macro_region_id)
      macro_region(macro_region_id)&.fetch("periods", []) || []
    end

    def period(macro_region_id, period_id)
      periods_for(macro_region_id).find { |row| row["id"].to_s == period_id.to_s }
    end

    def period!(macro_region_id, period_id)
      period(macro_region_id, period_id) || raise(ActiveRecord::RecordNotFound, "Unknown atlas period")
    end

    def entries_for(macro_region_id:, period_id: nil)
      ids = if period_id.present?
              Array(period(macro_region_id, period_id)&.fetch("entry_ids", []))
            else
              Array(macro_region(macro_region_id)&.fetch("entry_ids", []))
            end
      ids.filter_map { |id| find(id) }
    end

    def find_by_corpus(root:, period:, polity:)
      key = [root, period, polity].map(&:to_s).join("\u0000")
      id = payload.fetch("indexes").fetch("entry_by_corpus_key", {})[key]
      find(id)
    end

    def search(query, macro_region_id: nil, period_id: nil, limit: 200)
      needle = normalise_search_text(query)
      return [] if needle.blank?

      pool = if macro_region_id.present?
               entries_for(macro_region_id: macro_region_id, period_id: period_id)
             else
               entries
             end

      pool.filter_map do |entry|
        fields = [entry.title, entry.hanzi, *entry.aliases, entry.polity, *entry.periods, *entry.macro_regions]
        normalized = fields.map { |value| normalise_search_text(value) }
        exact = normalized.include?(needle)
        prefix = normalized.any? { |value| value.start_with?(needle) }
        contains = normalized.any? { |value| value.include?(needle) }
        next unless contains

        rank = exact ? 0 : (prefix ? 1 : 2)
        [rank, entry.title, entry]
      end.sort_by { |rank, title, _entry| [rank, title] }.first(limit).map(&:last)
    end

    def validate!
      ensure_loaded!
      ids = entries.map(&:id)
      duplicates = ids.group_by(&:itself).select { |_id, rows| rows.length > 1 }.keys
      raise Invalid, "Duplicate atlas IDs: #{duplicates.join(', ')}" if duplicates.any?

      entries.each do |entry|
        raise Invalid, "Atlas entry #{entry.id} has no article path" if entry.article_path.blank?
        unknown = entry.related_ids.reject { |id| find(id) }
        raise Invalid, "Unknown related IDs for #{entry.id}: #{unknown.join(', ')}" if unknown.any?
      end

      Atlas::UnicodeGuard.validate!(payload, context: "compiled atlas catalogue")
      true
    end

    private

    def payload
      ensure_loaded!
      @payload
    end

    def ensure_loaded!
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Production catalogues are immutable for the lifetime of a process. In
      # development, check at most once per second so one request does not turn
      # into dozens of NTFS/OneDrive stat calls.
      return if @payload && (!Rails.env.development? || now < @next_reload_check_at)

      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @payload && (!Rails.env.development? || now < @next_reload_check_at)

        path, loader = preferred_source
        signature = source_signature(path)
        if @payload && @signature == signature
          @next_reload_check_at = now + DEVELOPMENT_RELOAD_INTERVAL
          return
        end

        parsed = loader.call
        load_payload!(parsed)
        @signature = signature
        @next_reload_check_at = now + DEVELOPMENT_RELOAD_INTERVAL
      end
    end

    def preferred_source
      cache_path = cache_store.absolute(CACHE_PATH)
      return [cache_path, -> { cache_store.read_json(CACHE_PATH) }] if cache_path.file?

      raise Missing,
        "The atlas catalogue has not been built. Run bin/rails atlas:rebuild_catalogue " \
        "after building the corpus manifest."
    end

    def source_signature(path)
      stat = path.stat
      [path.to_s, stat.mtime.to_f, stat.size]
    rescue Errno::ENOENT
      [path.to_s, nil, nil]
    end

    def load_payload!(parsed)
      unless parsed.is_a?(Hash) && parsed["version"].to_i == VERSION
        raise Invalid, "Unsupported or malformed atlas catalogue"
      end
      raise Invalid, "Atlas catalogue entries must be a list" unless parsed["entries"].is_a?(Array)
      raise Invalid, "Atlas catalogue macro_regions must be a list" unless parsed["macro_regions"].is_a?(Array)
      raise Invalid, "Atlas catalogue indexes must be a mapping" unless parsed["indexes"].is_a?(Hash)

      Atlas::UnicodeGuard.validate!(parsed, context: "atlas catalogue")

      @payload = parsed.freeze
      @entries = parsed.fetch("entries").map { |row| Entry.new(row) }.freeze
      @entries_by_id = @entries.index_by(&:id).freeze
      @aliases = Grammar::MarkdownDocument.stringify_keys(parsed.fetch("aliases", {})).freeze
      @macro_regions_by_id = parsed.fetch("macro_regions").index_by { |row| row.fetch("id").to_s }.freeze
    end

    def macro_regions_by_id
      ensure_loaded!
      @macro_regions_by_id
    end

    def normalise_search_text(value)
      value.to_s.unicode_normalize(:nfkc).downcase.strip
    rescue Encoding::CompatibilityError
      value.to_s.downcase.strip
    end
  end
end
