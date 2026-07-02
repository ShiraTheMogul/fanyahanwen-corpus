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
    @directory.join("warnings.txt").write("One warning\n")
    @directory.join("analysis_report.json").write(JSON.generate(
      "version" => 1,
      "overall" => { "occurrences" => 3 },
      "charts" => [
        {
          "key" => "period_occurrences",
          "dimension" => "period",
          "metric" => "occurrences",
          "svg" => "figures/period_occurrences.svg"
        }
      ],
      "tables" => { "top_documents" => "top_documents.csv" }
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
    assert_equal ["One warning"], report.warnings
  end

  test "does not follow traversal paths from the report" do
    payload = JSON.parse(@directory.join("analysis_report.json").read)
    payload["tables"]["top_documents"] = "../secret.csv"
    @directory.join("analysis_report.json").write(JSON.generate(payload))

    report = CorpusSearch::AnalysisReport.load(@directory)
    assert_equal [], report.table("top_documents")
  end
end
