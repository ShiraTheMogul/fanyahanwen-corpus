# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class IdsDiagnosticTest < ActiveSupport::TestCase
  test "reports a clean source without writing database rows" do
    io = StringIO.new("𫜺\t⿱山田\n一\t#(H)(.);{一}#(T)(t)\n")
    before = CharacterStructure.count

    result = Ids::Diagnostic.new.run(level: "lv1", io: io)

    assert result.clean?
    assert_equal 2, result.rows
    assert_equal 3, result.candidates
    assert_equal 0, result.source_errors
    assert_equal 0, result.candidate_errors
    assert_equal before, CharacterStructure.count
  end

  test "separates source-row and candidate parse errors" do
    io = StringIO.new("⿰\t⿰日月\n明\t⿰日\n")

    result = Ids::Diagnostic.new.run(level: "lv1", io: io)

    refute result.clean?
    assert_equal 1, result.source_errors
    assert_equal 1, result.candidate_errors
    assert_equal 0, result.empty_rows
  end
end
