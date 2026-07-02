require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchRAnalysisRunnerTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("r-analysis-runner"))
    @documents = @directory.join("document_counts.csv")
    @results = @directory.join("results.csv")
    @documents.write("doc_id,path,folder_path,document_role,title,author,year_start,year_end,nation,period,region,searchable_characters,occurrences,matching_document\n1,a.txt,root,canonical,A,,1,1,N,P,R,10,2,1\n")
    @results.write("occurrence_id,mode,path,doc_id,search_start_offset,search_end_offset\n1,exact,a.txt,1,0,1\n")
    @comparison = @directory.join("comparison.csv")
    @comparison.write("dimension,left_group,right_group\nperiod,北宋,南宋\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
    CorpusSearch::RAnalysisRunner.reset_runtime_cache!
  end

  test "records an unavailable R runtime without accepting visitor code" do
    result = CorpusSearch::RAnalysisRunner.new(executable: @directory.join("missing-Rscript").to_s).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @results,
      output_dir: @directory.join("output")
    )

    assert_equal "unavailable", result.status
    assert result.metadata_path.file?
    assert @directory.join("output/analysis.R").file?
    assert @directory.join("output/warnings.txt").file?
  end

  test "runs the fixed standard profile through a controlled executable" do
    fake = @directory.join("Rscript")
    fake.write(<<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "R scripting front-end version TEST"
        exit 0
      fi
      output="$5"
      printf '{"version":1,"profile":"standard_analysis","overall":{},"charts":[],"tables":{}}\n' > "$output/analysis_report.json"
      printf 'metric,value\ndocuments,1\n' > "$output/summary.csv"
      printf 'R version TEST\n' > "$output/sessionInfo.txt"
      : > "$output/warnings.txt"
      exit 0
    SH
    fake.chmod(0o755)

    result = CorpusSearch::RAnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @results,
      output_dir: @directory.join("output")
    )

    assert result.success?
    assert_equal 0, result.exit_status
    assert @directory.join("output/analysis_report.json").file?
    assert_match(/TEST/, result.r_version)
  end

  test "passes an optional comparison definition to the fixed profile" do
    fake = @directory.join("Rscript-comparison")
    fake.write(<<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "R scripting front-end version TEST"
        exit 0
      fi
      output="$5"
      comparison="$6"
      test -f "$comparison" || exit 9
      printf '{"version":2,"profile":"standard_analysis","overall":{},"comparison":{"dimension":"period"},"charts":[],"tables":{}}\n' > "$output/analysis_report.json"
      : > "$output/warnings.txt"
      exit 0
    SH
    fake.chmod(0o755)

    result = CorpusSearch::RAnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @results,
      output_dir: @directory.join("comparison-output"),
      comparison_path: @comparison
    )

    assert result.success?
    metadata = JSON.parse(result.metadata_path.read)
    assert_equal 3, metadata["inputs"].length
    assert_equal @comparison.expand_path.to_s, metadata["inputs"].last["path"]
  end
end
