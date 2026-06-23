require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Load the whole application when the process starts.
  config.eager_load = true

  # Do not expose exception pages or local debugging information.
  config.consider_all_requests_local = false

  config.action_controller.perform_caching = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Keep uploads on the server filesystem. The deployment instructions keep
  # this directory outside code-only rsync operations.
  config.active_storage.service = :local

  # Mythic Beasts terminates TLS at Apache before forwarding to Puma. Leave
  # these switches off until certificates work for both hostnames, then set
  # RAILS_FORCE_SSL=1 in the server environment file.
  force_ssl = ENV.fetch("RAILS_FORCE_SSL", "0") == "1"
  config.assume_ssl = force_ssl
  config.force_ssl = force_ssl

  config.log_tags = [ :request_id ]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  # A small in-process cache avoids creating another database on the first
  # deployment. It is disposable and resets when Puma restarts.
  config.cache_store = :memory_store, { size: 64.megabytes }

  # Long corpus exports must survive web requests. Solid Queue uses its own
  # small SQLite database and is run by a separate systemd user service.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
  config.solid_queue.logger = ActiveSupport::TaggedLogging.logger(STDOUT)

  config.action_mailer.default_url_options = {
    host: "www.fanyahanwen-corpus.cn",
    protocol: force_ssl ? "https" : "http"
  }

  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]

  # Accept only the two public hostnames (plus the health-check hostname used
  # by local command-line checks).
  config.hosts = [
    "www.fanyahanwen-corpus.cn",
    "fanyahanwen-corpus.cn",
    "localhost"
  ]
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
