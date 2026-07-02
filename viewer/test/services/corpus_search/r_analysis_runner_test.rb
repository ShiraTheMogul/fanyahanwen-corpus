require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchRAnalysisRunnerTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("r-analysis-runner"))
    @input = @directory.join("document_counts.csv")
    @input.write("doc_id,document_role,searchable_characters,occurrences,matching_document\n1,canonical,10,2,1\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
    CorpusSearch::RAnalysisRunner.reset_runtime_cache!
  end

  test "records an unavailable R runtime without accepting visitor code" do
    result = CorpusSearch::RAnalysisRunner.new(executable: @directory.join("missing-Rscript").to_s).run(
      profile: "dataset_summary",
      input_path: @input,
      output_dir: @directory.join("output")
    )

    assert_equal "unavailable", result.status
    assert result.metadata_path.file?
    assert @directory.join("output/analysis.R").file?
    assert @directory.join("output/warnings.txt").file?
  end

  test "runs a fixed profile through a controlled executable" do
    fake = @directory.join("Rscript")
    fake.write(<<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "R scripting front-end version TEST"
        exit 0
      fi
      output="$4"
      printf 'metric,value\ndocuments,1\n' > "$output/summary.csv"
      printf 'R version TEST\n' > "$output/sessionInfo.txt"
      : > "$output/warnings.txt"
      exit 0
    SH
    fake.chmod(0o755)

    result = CorpusSearch::RAnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
      profile: "dataset_summary",
      input_path: @input,
      output_dir: @directory.join("output")
    )

    assert result.success?
    assert_equal 0, result.exit_status
    assert @directory.join("output/summary.csv").file?
    assert_match(/TEST/, result.r_version)
  end
end
