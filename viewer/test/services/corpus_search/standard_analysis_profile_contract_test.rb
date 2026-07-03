require_relative "../../test_helper"

class CorpusSearchStandardAnalysisProfileContractTest < ActiveSupport::TestCase
  test "ships the phase nine advanced output contract" do
    script = Rails.root.join("analysis/r/profiles/standard_analysis.R").read

    assert_includes script, '"neighbour_characters.csv"'
    assert_includes script, '"dispersion_summary.csv"'
    assert_includes script, '"time_trend_model.csv"'
    assert_includes script, '"duplicate_body_groups.csv"'
    assert_includes script, '"exact_body_sensitivity.csv"'
    assert_includes script, 'offset = log(searchable_characters)'
    assert_includes script, 'dp / maximum'
    assert_includes script, '"character_form_summary.csv"'
    assert_includes script, '"sampling_manifest.csv"'
    assert_includes script, '"comparison_neighbour_keyness.csv"'
    assert_includes script, 'sampling_seed <- 202609L'
  end
end
