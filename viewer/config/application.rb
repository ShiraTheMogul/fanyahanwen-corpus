require_relative "boot"
require_relative "interface_locales"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RailsBoilerPlate
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks dohliam])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
    config.active_job.queue_adapter = :sidekiq

    # Locale files are grouped by feature under config/locales/<locale>/.
    # English is the source catalogue. Every staged locale mirrors its keys as
    # explicit placeholders so translators can see the full interface surface.
    # English remains the safety fallback for any newly added key.
    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.{rb,yml}")]
    config.i18n.default_locale = InterfaceLocales::SOURCE
    config.i18n.available_locales = InterfaceLocales::ALL
    config.i18n.fallbacks = InterfaceLocales::ALL
      .reject { |locale| locale == InterfaceLocales::SOURCE }
      .to_h { |locale| [locale, InterfaceLocales::SOURCE] }
    config.i18n.enforce_available_locales = true
	
	# Ensure this loads it fucks up sometimes
	config.autoload_paths << Rails.root.join("app/lib")
    config.eager_load_paths << Rails.root.join("app/lib")
  end
end
