require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchAnalysisRunnerTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("analysis-runner"))
    @documents = @directory.join("document_counts.csv")
    @occurrences = @directory.join("analysis_occurrences.csv")
    @documents.write("doc_id,body_fingerprint,path,folder_path,document_role,title,author,year_start,year_end,nation,period,region,searchable_characters,occurrences,matching_document\n1,a,a.txt,root,canonical,A,,1,1,N,P,R,10,2,1\n")
    @occurrences.write("occurrence_id,mode,path,doc_id,search_start_offset,search_end_offset,matched_forms,left_neighbours,right_neighbours\n1,exact,a.txt,1,0,1,A⇒A,左,右\n")
    @comparison = @directory.join("comparison.csv")
    @comparison.write("dimension,left_group,right_group\nperiod,北宋,南宋\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
    CorpusSearch::AnalysisRunner.reset_runtime_cache!
  end

  test "records an unavailable Ruby runtime without accepting visitor code" do
    result = CorpusSearch::AnalysisRunner.new(executable: @directory.join("missing-ruby").to_s).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @occurrences,
      output_dir: @directory.join("output")
    )

    assert_equal "unavailable", result.status
    assert result.metadata_path.file?
    assert @directory.join("output/analysis.rb").file?
    assert @directory.join("output/warnings.txt").file?
    assert @directory.join("output/stdout.txt").file?
    assert @directory.join("output/stderr.txt").file?
  end

  test "runs the fixed standard profile through a controlled executable" do
    fake = fake_executable("ruby-test", <<~SH)
      output="$4"
      printf '{"version":5,"profile":"standard_analysis","overall":{},"charts":[],"tables":{}}\n' > "$output/analysis_report.json"
      printf 'metric,value\ndocuments,1\n' > "$output/summary.csv"
      printf 'Ruby TEST\n' > "$output/runtime_info.txt"
      : > "$output/warnings.txt"
      exit 0
    SH

    result = CorpusSearch::AnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @occurrences,
      output_dir: @directory.join("output")
    )

    assert result.success?
    assert_equal 0, result.exit_status
    assert @directory.join("output/analysis_report.json").file?
    assert_match(/TEST/, result.ruby_version)
  end

  test "passes an optional comparison definition to the fixed profile" do
    fake = fake_executable("ruby-comparison", <<~SH)
      output="$4"
      comparison="$5"
      test -f "$comparison" || exit 9
      printf '{"version":5,"profile":"standard_analysis","overall":{},"comparison":{"dimension":"period"},"charts":[],"tables":{}}\n' > "$output/analysis_report.json"
      : > "$output/warnings.txt"
      exit 0
    SH

    result = CorpusSearch::AnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @occurrences,
      output_dir: @directory.join("comparison-output"),
      comparison_path: @comparison
    )

    assert result.success?
    metadata = JSON.parse(result.metadata_path.read)
    assert_equal 3, metadata["inputs"].length
    assert_equal @comparison.expand_path.to_s, metadata["inputs"].last["path"]
  end

  test "does not mark a malformed report complete" do
    fake = fake_executable("ruby-malformed", <<~SH)
      output="$4"
      printf '{not-json' > "$output/analysis_report.json"
      exit 0
    SH

    result = CorpusSearch::AnalysisRunner.new(executable: fake.to_s, timeout_seconds: 5).run(
      profile: "standard_analysis",
      document_counts_path: @documents,
      occurrences_path: @occurrences,
      output_dir: @directory.join("malformed-output")
    )

    assert_equal "failed", result.status
    assert_equal 0, result.exit_status
  end

  private

  def fake_executable(name, body)
    path = @directory.join(name)
    path.write(<<~SH)
      #!/bin/sh
      if [ "$1" = "-v" ]; then
        echo "ruby TEST"
        exit 0
      fi
      #{body}
    SH
    path.chmod(0o755)
    path
  end
end
