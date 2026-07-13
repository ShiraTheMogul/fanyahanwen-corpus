# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "time"
require "pathname"
require "uri"

module CorpusSearch
  # Filesystem-backed record for a long-running search/export.
  #
  # This stores job state rather than corpus text. The secret key lets a
  # no-account user return to a prepared analysis without making every research
  # export publicly guessable. Full-corpus jobs also carry short-lived HMAC
  # client keys so the site can enforce accountless abuse protection.
  class PreparedSearch
    RECORD_VERSION = 10
    STATUSES = %w[queued running complete failed cancel_requested cancelled].freeze
    ACTIVE_FULL_SEARCH_STATUSES = %w[queued running complete].freeze
    DEFAULT_EXPIRY_HOURS = 72
    ATOMIC_WRITE_RETRYABLE_ERRORS = [Errno::EACCES, Errno::EPERM, Errno::EBUSY].freeze
    DEFAULT_ATOMIC_WRITE_RETRIES = 8
    DEFAULT_ATOMIC_WRITE_RETRY_SLEEP = 0.05

    attr_reader :id, :key, :payload

    def self.create!(query:, locale: I18n.locale, comparison: nil, source_prepared: nil, cache_store: CacheStore.new,
      full_search: false, client_identity: nil, notification_email: nil)
      id = SecureRandom.hex(8)
      key = SecureRandom.urlsafe_base64(24)
      prepared = new(id: id, key: key, cache_store: cache_store)
      prepared.write_initial!(
        query: query,
        locale: locale,
        comparison: comparison,
        source_prepared: source_prepared,
        full_search: full_search,
        client_identity: client_identity,
        notification_email: notification_email
      )
      prepared
    end

    def self.find(id:, key:, cache_store: CacheStore.new)
      prepared = new(id: id, key: key, cache_store: cache_store)
      prepared.load!
      return nil unless prepared.authorized?

      prepared
    rescue Errno::ENOENT, JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      nil
    end

    def self.find_internal(id:, cache_store: CacheStore.new)
      prepared = new(id: id, key: "", cache_store: cache_store)
      prepared.load!
      prepared
    rescue Errno::ENOENT, JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      nil
    end

    def self.active_full_search_for_client?(client_identity, cache_store: CacheStore.new, email_key: nil)
      keys = client_identity.to_h.values.compact
      keys << email_key if email_key.present?
      return false if keys.empty?

      active_full_searches(cache_store: cache_store).any? do |prepared|
        client = prepared.payload.fetch("client", {})
        notification = prepared.payload.fetch("notification", {}) || {}
        keys.include?(client["ip_key"]) ||
          keys.include?(client["cookie_key"]) ||
          keys.include?(notification["email_key"])
      end
    end

    def self.active_full_search_count(cache_store: CacheStore.new)
      active_full_searches(cache_store: cache_store).count
    end

    def self.active_full_searches(cache_store: CacheStore.new)
      root = cache_store.absolute("prepared")
      return [] unless root.directory?

      root.children.filter_map do |dir|
        next unless dir.directory?

        prepared = find_internal(id: dir.basename.to_s, cache_store: cache_store)
        next unless prepared&.active_full_search?

        prepared
      end
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

    def write_initial!(query:, locale:, comparison:, source_prepared:, full_search:, client_identity:, notification_email:)
      FileUtils.mkdir_p(@dir)
      notification = notification_payload(notification_email)
      @payload = {
        "version" => RECORD_VERSION,
        "id" => safe_id,
        "key_digest" => digest(@key),
        "status" => "queued",
        "locale" => locale.to_s,
        "query" => query.to_h,
        "comparison" => comparison&.requested? ? comparison.to_h : nil,
        "source_prepared_id" => source_prepared&.id,
        "live_query_path" => query.relative_url(include_presentation: false),
        "normalization_profile_version" => query.normalization_profile_version,
        "full_search" => full_search ? true : false,
        "client" => client_identity&.to_h.to_h,
        "notification" => notification,
        "cancel_requested" => false,
        "created_at" => Time.now.utc.iso8601,
        "started_at" => nil,
        "updated_at" => Time.now.utc.iso8601,
        "completed_at" => nil,
        "duration_seconds" => nil,
        "downloaded_at" => nil,
        "expires_at" => DEFAULT_EXPIRY_HOURS.hours.from_now.utc.iso8601,
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

    def record_version
      @payload["version"].to_i
    end

    def current_record_version?
      record_version == RECORD_VERSION
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

    def cancelled?
      status == "cancelled"
    end

    def cancel_requested?
      @payload["cancel_requested"] == true || status == "cancel_requested"
    end

    def full_search?
      @payload["full_search"] == true
    end

    def downloaded?
      @payload["downloaded_at"].present?
    end

    def expired?
      expires_at = @payload["expires_at"].presence
      expires_at.present? && Time.iso8601(expires_at) <= Time.now.utc
    rescue ArgumentError
      false
    end

    def active_full_search?
      full_search? && ACTIVE_FULL_SEARCH_STATUSES.include?(status) && !downloaded? && !expired?
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

    def request_cancel!
      load! unless @payload
      return false unless %w[queued running].include?(status)

      @payload["status"] = "cancel_requested"
      @payload["cancel_requested"] = true
      @payload["progress"] = @payload.fetch("progress", {}).merge("stage" => "cancelling")
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
      true
    end

    def cancel!(message: nil)
      load! unless @payload
      @payload["status"] = "cancelled"
      @payload["cancel_requested"] = true
      @payload["progress"] = @payload.fetch("progress", {}).merge("stage" => "cancelled")
      @payload["error_message"] = message if message.present?
      clear_client_keys!
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
      true
    end

    def mark_downloaded!
      load! unless @payload
      @payload["downloaded_at"] ||= Time.now.utc.iso8601
      clear_client_keys!
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
      true
    end

    def update!(status: nil, progress: nil, outputs: nil, error_message: nil)
      load! unless @payload
      return false if complete? || cancelled?

      if status && STATUSES.include?(status)
        @payload["status"] = status
        @payload["started_at"] ||= Time.now.utc.iso8601 if status == "running"
      end
      @payload["progress"] = @payload.fetch("progress", {}).merge(progress) if progress
      @payload["outputs"] = @payload.fetch("outputs", {}).merge(outputs) if outputs
      @payload["error_message"] = error_message if error_message
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
      true
    end

    def complete!(progress:, outputs:, corpus_snapshot:, artifact_manifest:)
      load! unless @payload
      return false if complete? || cancelled?

      completed_at = Time.now.utc.iso8601
      next_payload = @payload.deep_dup
      next_payload["status"] = "complete"
      next_payload["cancel_requested"] = false
      next_payload["progress"] = next_payload.fetch("progress", {}).merge(progress).merge("stage" => "complete")
      next_payload["outputs"] = next_payload.fetch("outputs", {}).merge(outputs)
      next_payload["error_message"] = nil
      next_payload["completed_at"] = completed_at
      next_payload["updated_at"] = completed_at
      started_at = next_payload["started_at"].presence || next_payload["created_at"]
      next_payload["duration_seconds"] = (Time.iso8601(completed_at) - Time.iso8601(started_at)).round(3)

      frozen_payload = {
        "version" => 1,
        "id" => safe_id,
        "created_at" => next_payload["created_at"],
        "completed_at" => completed_at,
        "started_at" => next_payload["started_at"],
        "duration_seconds" => next_payload["duration_seconds"],
        "query" => next_payload["query"],
        "comparison" => next_payload["comparison"],
        "source_prepared_id" => next_payload["source_prepared_id"],
        "live_query_path" => next_payload["live_query_path"],
        "full_search" => next_payload["full_search"],
        "corpus_snapshot" => corpus_snapshot,
        "outputs" => next_payload["outputs"],
        "artifacts" => artifact_manifest
      }

      atomic_write(@frozen_record_path, JSON.pretty_generate(frozen_payload))
      @payload = next_payload
      save!
      true
    end

    def notification_email
      notification = @payload.fetch("notification", {})
      ClientIdentity.decrypt_email(notification["email_encrypted"])
    end

    def notification_pending?
      notification_email.present? && @payload.dig("notification", "notified_at").blank?
    end

    def mark_notification_sent!
      load! unless @payload
      notification = @payload["notification"] ||= {}
      notification["notified_at"] = Time.now.utc.iso8601
      notification.delete("email_encrypted")
      @payload["updated_at"] = Time.now.utc.iso8601
      save!
      true
    end

    def output_dir
      FileUtils.mkdir_p(@dir.join("outputs"))
      @dir.join("outputs")
    end

    private

    def notification_payload(email)
      normalised = email.to_s.strip
      return nil if normalised.blank?
      return nil unless normalised.match?(URI::MailTo::EMAIL_REGEXP)

      {
        "email_encrypted" => ClientIdentity.encrypt_email(normalised),
        "email_key" => ClientIdentity.email_key(normalised),
        "notified_at" => nil
      }
    end

    def clear_client_keys!
      @payload["client"] = {}
      if @payload["notification"].is_a?(Hash)
        @payload["notification"].delete("email_key")
      end
    end

    def save!
      atomic_write(@status_path, JSON.pretty_generate(@payload))
    end

    def atomic_write(path, contents)
      FileUtils.mkdir_p(path.dirname)
      temporary = path.dirname.join(".#{path.basename}.#{$$}.#{SecureRandom.hex(4)}.tmp")
      temporary.write(contents)
      rename_with_retries(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def rename_with_retries(source, target)
      attempts = 0

      begin
        File.rename(source, target)
      rescue *ATOMIC_WRITE_RETRYABLE_ERRORS
        attempts += 1
        raise if attempts > atomic_write_retry_limit

        sleep(atomic_write_retry_sleep(attempts))
        retry
      end
    end

    def atomic_write_retry_limit
      value = Integer(ENV.fetch("CORPUS_SEARCH_ATOMIC_WRITE_RETRIES", DEFAULT_ATOMIC_WRITE_RETRIES.to_s))
      value.negative? ? 0 : value
    rescue ArgumentError, TypeError
      DEFAULT_ATOMIC_WRITE_RETRIES
    end

    def atomic_write_retry_sleep(attempt)
      base = Float(ENV.fetch("CORPUS_SEARCH_ATOMIC_WRITE_RETRY_SLEEP", DEFAULT_ATOMIC_WRITE_RETRY_SLEEP.to_s))
      base = DEFAULT_ATOMIC_WRITE_RETRY_SLEEP if base.negative?
      multiplier = 2 ** [attempt - 1, 5].min
      base * multiplier
    rescue ArgumentError, TypeError
      DEFAULT_ATOMIC_WRITE_RETRY_SLEEP
    end

    def safe_id
      @id.gsub(/[^a-zA-Z0-9_-]/, "")
    end

    def digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end
  end
end
