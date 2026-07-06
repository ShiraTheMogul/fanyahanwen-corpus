require_relative "../../test_helper"

class CorpusSearchStandardAnalysisProfileContractTest < ActiveSupport::TestCase
  test "ships the advanced Ruby output contract" do
    script = Rails.root.join("analysis/ruby/profiles/standard_analysis.rb").read

    assert_includes script, '"neighbour_characters.csv"'
    assert_includes script, '"dispersion_summary.csv"'
    assert_includes script, '"time_trend_model.csv"'
    assert_includes script, '"duplicate_body_groups.csv"'
    assert_includes script, '"exact_body_sensitivity.csv"'
    assert_includes script, "Math.log"
    assert_includes script, "dp / maximum"
    assert_includes script, '"character_form_summary.csv"'
    assert_includes script, '"sampling_manifest.csv"'
    assert_includes script, '"comparison_neighbour_keyness.csv"'
    assert_includes script, "SAMPLING_SEED = 202_609"
  end
end
