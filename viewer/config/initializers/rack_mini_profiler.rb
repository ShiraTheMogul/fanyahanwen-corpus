if Rails.env.development?
  begin
    Rack::MiniProfilerRails.initialize!(Rails.application)
    Rack::MiniProfiler.config.position = 'right'
  rescue StandardError
  end
end
