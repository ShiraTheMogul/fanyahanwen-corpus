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
  # This intentionally stores job state, not corpus text. The secret key lets a
  # no-account user return to their prepared search without making all exports
  # publicly guessable.
  class PreparedSearch
    STATUSES = %w[queued running complete failed].freeze

    attr_reader :id, :key, :payload

    def self.create!(query:, locale: I18n.locale, cache_store: CacheStore.new)
      id = SecureRandom.hex(8)
      key = SecureRandom.urlsafe_base64(24)
      prepared = new(id: id, key: key, cache_store: cache_store)
      prepared.write_initial!(query: query, locale: locale)
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
      @payload = nil
    end

    def write_initial!(query:, locale:)
      FileUtils.mkdir_p(@dir)
      @payload = {
        "version" => 7,
        "id" => safe_id,
        "key_digest" => digest(@key),
        "status" => "queued",
        "locale" => locale.to_s,
        "query" => query.to_h,
        "live_query_path" => query.relative_url(include_presentation: false),
        "normalization_profile_version" => query.normalization_profile_version,
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => Time.now.utc.iso8601,
        "progress" => {
          "files_total" => 0,
          "files_scanned" => 0,
          "hits_found" => 0,
          "stage" => "queued"
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

    def zip_path
      value = @payload.dig("outputs", "zip_path")
      value.present? ? Pathname(value) : nil
    end

    def public_params
      { id: safe_id, key: @key }
    end

    def update!(status: nil, progress: nil, outputs: nil, error_message: nil)
      load! unless @payload

      @payload["status"] = status if status && STATUSES.include?(status)
      @payload["progress"] = @payload.fetch("progress", {}).merge(progress) if progress
      @payload["outputs"] = @payload.fetch("outputs", {}).merge(outputs) if outputs
      @payload["error_message"] = error_message if error_message
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
    end

    def output_dir
      FileUtils.mkdir_p(@dir.join("outputs"))
      @dir.join("outputs")
    end

    private

    def save!
      FileUtils.mkdir_p(@dir)
      @status_path.write(JSON.pretty_generate(@payload))
    end

    def safe_id
      @id.gsub(/[^a-zA-Z0-9_-]/, "")
    end

    def digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end
  end
end
