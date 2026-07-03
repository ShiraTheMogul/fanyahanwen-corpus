require_relative "../../test_helper"
require "fileutils"
require "json"
require "tmpdir"

class CorpusSearchAnalysisReportTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("analysis-report"))
    FileUtils.mkdir_p(@directory.join("figures"))
    @directory.join("figures/period_occurrences.svg").write("<?xml version=\"1.0\"?><svg><text>Period</text></svg>")
    @directory.join("top_documents.csv").write("title,path,occurrences\nText,a.txt,3\n")
    @directory.join("period_summary.csv").write("group,occurrences\n北宋,2\n南宋,1\n")
    @directory.join("comparison_summary.csv").write("scope,scope_label,occurrences\nleft,北宋,2\nright,南宋,1\n")
    @directory.join("comparison_effects.csv").write("measure,value\nrate_ratio_left_over_right,2\n")
    @directory.join("dispersion_summary.csv").write("measure,value\ndp_norm,0.25\n")
    @directory.join("warnings.txt").write("One warning\n")
    @directory.join("analysis_report.json").write(JSON.generate(
      "version" => 4,
      "overall" => { "occurrences" => 3 },
      "comparison" => {
        "dimension" => "period",
        "left_group" => "北宋",
        "right_group" => "南宋",
        "summary_table" => "comparison_summary.csv",
        "effects_table" => "comparison_effects.csv",
        "chart_key" => "scope_comparison"
      },
      "charts" => [
        {
          "key" => "period_occurrences",
          "dimension" => "period",
          "metric" => "occurrences",
          "svg" => "figures/period_occurrences.svg"
        }
      ],
      "tables" => {
        "top_documents" => "top_documents.csv",
        "period" => "period_summary.csv",
        "comparison_summary" => "comparison_summary.csv",
        "comparison_effects" => "comparison_effects.csv",
        "dispersion" => "dispersion_summary.csv"
      }
    ))
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "loads chart, table, and warnings from the controlled directory" do
    report = CorpusSearch::AnalysisReport.load(@directory)

    assert_equal 3, report.overall["occurrences"]
    chart = report.chart(dimension: "period", metric: "occurrences")
    assert_match(/<svg>/, report.svg(chart))
    assert_equal "Text", report.table("top_documents").first["title"]
    assert_equal "0.25", report.table("dispersion").first["value"]
    assert_equal ["One warning"], report.warnings
  end

  test "loads comparison choices, summary, and effects" do
    report = CorpusSearch::AnalysisReport.load(@directory)

    assert report.comparison?
    assert_equal ["北宋", "南宋"], report.comparison_options("period")
    assert_equal "北宋", report.comparison_summary.first["scope_label"]
    assert_equal "rate_ratio_left_over_right", report.comparison_effects.first["measure"]
    assert_equal [], report.comparison_options("author")
  end

  test "does not follow traversal paths from the report" do
    payload = JSON.parse(@directory.join("analysis_report.json").read)
    payload["tables"]["top_documents"] = "../secret.csv"
    @directory.join("analysis_report.json").write(JSON.generate(payload))

    report = CorpusSearch::AnalysisReport.load(@directory)
    assert_equal [], report.table("top_documents")
  end
end
