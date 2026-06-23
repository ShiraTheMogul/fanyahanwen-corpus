# Puma serves the Rails application. On Mythic Beasts, Apache forwards public
# requests to a Unix socket supplied through PUMA_BIND.

threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
threads threads_count, threads_count

if ENV["PUMA_BIND"].to_s.empty?
  port Integer(ENV.fetch("PORT", 3000))
else
  bind ENV.fetch("PUMA_BIND")
end

# A single worker is deliberate on shared hosting. Threads still allow several
# requests to wait on filesystem/database work without duplicating the whole app.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 0))

plugin :tmp_restart
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
