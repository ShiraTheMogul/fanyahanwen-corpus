# frozen_string_literal: true

require "fileutils"
require "time"

module CorpusActivity
  # Builds a small, read-only activity index from the existing corpus-search
  # manifest. Web requests read this index instead of walking or sorting the
  # whole corpus.
  class SnapshotBuilder
    SUMMARY_SIZE = 10
    PAGE_SIZE = 50
    SHARD_SIZE = 1_000
    CACHE_ROOT = "activity"
    DERIVED_DIRECTORIES = %w[kanbun hanmun hanvan translation].freeze

    def initialize(manifest:, cache_store: CorpusSearch::CacheStore.new)
      @manifest = manifest
      @cache_store = cache_store
    end

    def build!
      documents = @manifest.documents.select { |document| canonical_document?(document) }
      recent_documents = documents.sort_by { |document| [-mtime(document), document["path"].to_s] }
      latest_texts = build_latest_texts(documents)

      clear_old_feed_files!
      recent_feed = write_feed("recent_changes", recent_documents) { |document| recent_change_entry(document) }
      latest_feed = write_feed("latest_texts", latest_texts) { |entry| entry }

      summary = {
        "version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "page_size" => PAGE_SIZE,
        "shard_size" => SHARD_SIZE,
        "feeds" => {
          "latest_texts" => latest_feed,
          "recent_changes" => recent_feed
        }
      }

      @cache_store.write_json("#{CACHE_ROOT}/summary.json.gz", summary)
      summary
    end

    private

    def canonical_document?(document)
      parts = document["path"].to_s.tr("\\", "/").split("/")
      return false unless parts.length >= 3
      return false unless parts[1] == "clean"
      return false if (parts & DERIVED_DIRECTORIES).any?

      File.extname(parts.last).casecmp?(".txt")
    end

    def build_latest_texts(documents)
      folders = {}

      documents.each do |document|
        folder_path = File.dirname(document["path"].to_s).tr("\\", "/")
        state = folders[folder_path] ||= {
          "path" => folder_path,
          "title" => clean_title(File.basename(folder_path)),
          "nation" => document["nation"].to_s,
          "period" => document["period"].to_s,
          "region" => document["region"].to_s,
          "file_count" => 0,
          "mtime" => 0.0
        }

        state["file_count"] += 1
        state["mtime"] = [state["mtime"], mtime(document)].max
      end

      folders.values
        .sort_by { |entry| [-entry["mtime"], entry["path"]] }
        .map do |entry|
          entry.merge("changed_at" => iso_time(entry.delete("mtime")))
        end
    end

    def recent_change_entry(document)
      path = document["path"].to_s.tr("\\", "/")
      folder_path = File.dirname(path)

      {
        "path" => path,
        "display_path" => path.sub(/\.txt\z/i, ""),
        "title" => clean_title(document["title"].presence || File.basename(path, ".txt")),
        "work_title" => clean_title(File.basename(folder_path)),
        "work_path" => folder_path,
        "nation" => document["nation"].to_s,
        "period" => document["period"].to_s,
        "region" => document["region"].to_s,
        "size" => document["size"].to_i,
        "changed_at" => iso_time(mtime(document))
      }
    end

    def write_feed(kind, records)
      top_items = []
      shard_number = 0

      records.each_slice(SHARD_SIZE) do |slice|
        shard_number += 1
        items = slice.map { |record| yield(record) }
        top_items.concat(items.first(SUMMARY_SIZE - top_items.length)) if top_items.length < SUMMARY_SIZE

        @cache_store.write_json(
          format("%<root>s/%<kind>s/shard-%<number>06d.json.gz", root: CACHE_ROOT, kind: kind, number: shard_number),
          { "items" => items }
        )
      end

      total = records.length
      {
        "total" => total,
        "total_pages" => total.zero? ? 0 : (total.to_f / PAGE_SIZE).ceil,
        "total_shards" => shard_number,
        "items" => top_items.first(SUMMARY_SIZE)
      }
    end

    def clear_old_feed_files!
      %w[latest_texts recent_changes].each do |kind|
        FileUtils.rm_rf(@cache_store.absolute("#{CACHE_ROOT}/#{kind}"))
      end
    end

    def clean_title(value)
      value.to_s.strip.sub(/\.txt\z/i, "")
    end

    def mtime(document)
      Float(document["mtime"] || 0)
    rescue ArgumentError, TypeError
      0.0
    end

    def iso_time(value)
      Time.at(value).utc.iso8601
    rescue ArgumentError, RangeError, TypeError
      Time.at(0).utc.iso8601
    end
  end
end
