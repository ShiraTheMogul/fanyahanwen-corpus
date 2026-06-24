# frozen_string_literal: true

module CorpusActivity
  # Reads one small summary file or one activity shard at a time.
  class Snapshot
    KINDS = %w[latest_texts recent_changes].freeze
    CACHE_ROOT = SnapshotBuilder::CACHE_ROOT

    def initialize(cache_store: CorpusSearch::CacheStore.new)
      @cache_store = cache_store
    end

    def summary
      @summary ||= @cache_store.read_json("#{CACHE_ROOT}/summary.json.gz") || empty_summary
    end

    def available?
      summary["generated_at"].present?
    end

    def page(kind:, number:)
      kind = normalized_kind(kind)
      page_number = positive_integer(number)
      feed = summary.fetch("feeds").fetch(kind)
      total_pages = feed["total_pages"].to_i

      return empty_page(kind, page_number, feed) if total_pages.zero?

      page_number = [page_number, total_pages].min
      page_size = summary["page_size"].to_i
      shard_size = summary["shard_size"].to_i
      first_index = (page_number - 1) * page_size
      shard_number = (first_index / shard_size) + 1
      within_shard = first_index % shard_size

      shard = @cache_store.read_json(
        format("%<root>s/%<kind>s/shard-%<number>06d.json.gz", root: CACHE_ROOT, kind: kind, number: shard_number)
      ) || { "items" => [] }

      {
        "kind" => kind,
        "page" => page_number,
        "page_size" => page_size,
        "total" => feed["total"].to_i,
        "total_pages" => total_pages,
        "items" => Array(shard["items"])[within_shard, page_size].to_a
      }
    end

    private

    def normalized_kind(kind)
      value = kind.to_s
      KINDS.include?(value) ? value : "recent_changes"
    end

    def positive_integer(value)
      number = Integer(value || 1)
      number.positive? ? number : 1
    rescue ArgumentError, TypeError
      1
    end

    def empty_page(kind, page_number, feed)
      {
        "kind" => kind,
        "page" => page_number,
        "page_size" => summary["page_size"].to_i,
        "total" => feed["total"].to_i,
        "total_pages" => 0,
        "items" => []
      }
    end

    def empty_summary
      {
        "version" => 1,
        "generated_at" => nil,
        "page_size" => SnapshotBuilder::PAGE_SIZE,
        "shard_size" => SnapshotBuilder::SHARD_SIZE,
        "feeds" => {
          "latest_texts" => { "total" => 0, "total_pages" => 0, "total_shards" => 0, "items" => [] },
          "recent_changes" => { "total" => 0, "total_pages" => 0, "total_shards" => 0, "items" => [] }
        }
      }
    end
  end
end
