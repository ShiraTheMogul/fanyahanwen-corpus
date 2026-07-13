require_relative "../../test_helper"

class CorpusSearchInteractiveLimitsTest < ActiveSupport::TestCase
  test "interactive cold scans stay deliberately small" do
    assert_equal 1_000, CorpusSearch::Runner::DEFAULT_INTERACTIVE_SCAN_LIMIT
    assert_equal 1_000, CorpusSearch::Runner::DEFAULT_INTERACTIVE_LIMIT
  end
end
