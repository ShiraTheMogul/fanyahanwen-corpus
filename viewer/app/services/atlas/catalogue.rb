# frozen_string_literal: true

require "json"
require "pathname"
require "thread"

module Atlas
  # Read-only runtime catalogue prepared by Atlas::CatalogueBuilder.
  #
  # Web requests load one compact JSON payload. They never traverse the corpus,
  # polity sources, or period sources. In development, the generated file is
  # checked at most once per second.
  class Catalogue
    VERSION = 3
    CACHE_PATH = "atlas/catalogue-v3.json.gz"
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
      @macro_regions_by_id = nil
      @periods_by_key = nil
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
      find(id) || raise(ActiveRecord::RecordNotFound, "Unknown atlas polity")
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

    def periods_for(macro_region_id, parent_id: nil, include_hidden: false)
      rows = if parent_id.present?
               Array(period(macro_region_id, parent_id)&.fetch("children", []))
             else
               Array(macro_region(macro_region_id)&.fetch("periods", []))
             end
      include_hidden ? rows : rows.reject { |row| row["hidden"] == true }
    end

    def all_periods_for(macro_region_id, include_hidden: true)
      rows = []
      walk = lambda do |period_rows|
        Array(period_rows).each do |row|
          rows << row if include_hidden || row["hidden"] != true
          walk.call(row["children"])
        end
      end
      walk.call(macro_region(macro_region_id)&.fetch("periods", []))
      rows
    end

    def period(macro_region_id, period_id)
      ensure_loaded!
      @periods_by_key[[macro_region_id.to_s, period_id.to_s]]
    end

    def period!(macro_region_id, period_id)
      period(macro_region_id, period_id) || raise(ActiveRecord::RecordNotFound, "Unknown atlas period")
    end

    def period_ancestors(macro_region_id, period_id)
      row = period(macro_region_id, period_id)
      return [] unless row

      ancestors = []
      parent_id = row["parent_id"].to_s.presence
      while parent_id
        parent = period(macro_region_id, parent_id)
        break unless parent
        ancestors.unshift(parent)
        parent_id = parent["parent_id"].to_s.presence
      end
      ancestors
    end

    def period_redirect_for_legacy_id(id)
      value = payload.fetch("indexes").fetch("period_redirect_by_legacy_id", {})[id.to_s]
      return nil unless value.is_a?(Array) && value.length == 2

      { "macro_region_id" => value[0].to_s, "period_id" => value[1].to_s }
    end

    def period_for_corpus_path(path)
      value = payload.fetch("indexes").fetch("period_by_corpus_path", {})[path.to_s]
      return nil unless value.is_a?(Array) && value.length == 2

      period(value[0], value[1])
    end

    def entries_for(macro_region_id:, period_id: nil, direct: false)
      ids = if period_id.present?
              row = period(macro_region_id, period_id)
              key = direct ? "direct_entry_ids" : "entry_ids"
              Array(row&.fetch(key, []))
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
        raise Invalid, "Atlas entry #{entry.id} is not a polity" unless entry.kind == "polity"
        raise Invalid, "Atlas entry #{entry.id} has no article path" if entry.article_path.blank?
        unknown = entry.related_ids.reject { |id| find(id) }
        raise Invalid, "Unknown related IDs for #{entry.id}: #{unknown.join(', ')}" if unknown.any?
      end

      macro_regions.each do |region|
        all_periods_for(region.fetch("id")).each do |row|
          parent_id = row["parent_id"].to_s.presence
          if parent_id && !period(region.fetch("id"), parent_id)
            raise Invalid, "Unknown parent period #{region['id']} / #{parent_id}"
          end
        end
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
      @periods_by_key = {}
      parsed.fetch("macro_regions").each do |region|
        index_period_rows!(region.fetch("id"), region.fetch("periods", []))
      end
      @periods_by_key.freeze
    end

    def index_period_rows!(region_id, rows)
      Array(rows).each do |row|
        key = [region_id.to_s, row.fetch("id").to_s]
        raise Invalid, "Duplicate period in catalogue: #{key.join(' / ')}" if @periods_by_key.key?(key)
        @periods_by_key[key] = row
        index_period_rows!(region_id, row["children"])
      end
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
