# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "time"
require "pathname"

module CorpusSearch
  # Filesystem-backed record for a long-running search/export.
  #
  # This stores job state rather than corpus text. The secret key lets a
  # no-account user return to a prepared analysis without making every research
  # export publicly guessable. Once complete, a separate frozen record captures
  # the final query, corpus snapshot, comparison, and artifact checksums.
  class PreparedSearch
    STATUSES = %w[queued running complete failed].freeze

    attr_reader :id, :key, :payload

    def self.create!(query:, locale: I18n.locale, comparison: nil, source_prepared: nil, cache_store: CacheStore.new)
      id = SecureRandom.hex(8)
      key = SecureRandom.urlsafe_base64(24)
      prepared = new(id: id, key: key, cache_store: cache_store)
      prepared.write_initial!(
        query: query,
        locale: locale,
        comparison: comparison,
        source_prepared: source_prepared
      )
      prepared
    end

    def self.find(id:, key:, cache_store: CacheStore.new)
      prepared = new(id: id, key: key, cache_store: cache_store)
      prepared.load!
      return nil unless prepared.authorized?

      prepared
    rescue Errno::ENOENT
      nil
    end

    def self.find_internal(id:, cache_store: CacheStore.new)
      prepared = new(id: id, key: "", cache_store: cache_store)
      prepared.load!
      prepared
    rescue Errno::ENOENT
      nil
    end

    def initialize(id:, key:, cache_store: CacheStore.new)
      @id = id.to_s
      @key = key.to_s
      @cache_store = cache_store
      @dir = @cache_store.absolute(File.join("prepared", safe_id))
      @status_path = @dir.join("status.json")
      @frozen_record_path = @dir.join("frozen_record.json")
      @payload = nil
    end

    def write_initial!(query:, locale:, comparison:, source_prepared:)
      FileUtils.mkdir_p(@dir)
      @payload = {
        "version" => 8,
        "id" => safe_id,
        "key_digest" => digest(@key),
        "status" => "queued",
        "locale" => locale.to_s,
        "query" => query.to_h,
        "comparison" => comparison&.requested? ? comparison.to_h : nil,
        "source_prepared_id" => source_prepared&.id,
        "live_query_path" => query.relative_url(include_presentation: false),
        "normalization_profile_version" => query.normalization_profile_version,
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => Time.now.utc.iso8601,
        "completed_at" => nil,
        "progress" => {
          "files_total" => 0,
          "files_scanned" => 0,
          "hits_found" => 0,
          "stage" => source_prepared ? "copying_source_dataset" : "queued"
        },
        "outputs" => {},
        "error_message" => nil
      }
      save!
    end

    def load!
      @payload = JSON.parse(@status_path.read)
      self
    end

    def authorized?
      @payload && ActiveSupport::SecurityUtils.secure_compare(@payload["key_digest"].to_s, digest(@key))
    rescue ArgumentError
      false
    end

    def query
      Query.from_h(@payload.fetch("query"), locale: locale)
    end

    def comparison
      value = @payload["comparison"]
      value.present? ? ComparisonDefinition.from_h(value) : nil
    end

    def source_prepared_id
      @payload["source_prepared_id"].presence
    end

    def source_prepared
      return nil unless source_prepared_id

      self.class.find_internal(id: source_prepared_id, cache_store: @cache_store)
    end

    def locale
      candidate = @payload["locale"].to_s
      I18n.available_locales.map(&:to_s).include?(candidate) ? candidate : I18n.default_locale
    end

    def status
      @payload["status"].to_s
    end

    def complete?
      status == "complete"
    end

    def failed?
      status == "failed"
    end

    def frozen?
      complete? && @frozen_record_path.file?
    end

    def frozen_record
      return nil unless @frozen_record_path.file?

      JSON.parse(@frozen_record_path.read)
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def zip_path
      value = @payload.dig("outputs", "zip_path")
      value.present? ? Pathname(value) : nil
    end

    def public_params
      { id: safe_id, key: @key }
    end

    def update!(status: nil, progress: nil, outputs: nil, error_message: nil)
      load! unless @payload
      return false if complete?

      @payload["status"] = status if status && STATUSES.include?(status)
      @payload["progress"] = @payload.fetch("progress", {}).merge(progress) if progress
      @payload["outputs"] = @payload.fetch("outputs", {}).merge(outputs) if outputs
      @payload["error_message"] = error_message if error_message
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
      true
    end

    def complete!(progress:, outputs:, corpus_snapshot:, artifact_manifest:)
      load! unless @payload
      return false if complete?

      completed_at = Time.now.utc.iso8601
      next_payload = @payload.deep_dup
      next_payload["status"] = "complete"
      next_payload["progress"] = next_payload.fetch("progress", {}).merge(progress).merge("stage" => "complete")
      next_payload["outputs"] = next_payload.fetch("outputs", {}).merge(outputs)
      next_payload["error_message"] = nil
      next_payload["completed_at"] = completed_at
      next_payload["updated_at"] = completed_at

      frozen_payload = {
        "version" => 1,
        "id" => safe_id,
        "created_at" => next_payload["created_at"],
        "completed_at" => completed_at,
        "query" => next_payload["query"],
        "comparison" => next_payload["comparison"],
        "source_prepared_id" => next_payload["source_prepared_id"],
        "live_query_path" => next_payload["live_query_path"],
        "corpus_snapshot" => corpus_snapshot,
        "outputs" => next_payload["outputs"],
        "artifacts" => artifact_manifest
      }

      atomic_write(@frozen_record_path, JSON.pretty_generate(frozen_payload))
      @payload = next_payload
      save!
      true
    end

    def output_dir
      FileUtils.mkdir_p(@dir.join("outputs"))
      @dir.join("outputs")
    end

    private

    def save!
      atomic_write(@status_path, JSON.pretty_generate(@payload))
    end

    def atomic_write(path, contents)
      FileUtils.mkdir_p(path.dirname)
      temporary = path.dirname.join(".#{path.basename}.#{$$}.#{SecureRandom.hex(4)}.tmp")
      temporary.write(contents)
      FileUtils.mv(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def safe_id
      @id.gsub(/[^a-zA-Z0-9_-]/, "")
    end

    def digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end
  end
end
