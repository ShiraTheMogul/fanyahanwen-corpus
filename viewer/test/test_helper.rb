ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    # Do not load every fixture into every test automatically.
    # Individual tests can opt into specific, valid fixtures when needed.
  end
end
