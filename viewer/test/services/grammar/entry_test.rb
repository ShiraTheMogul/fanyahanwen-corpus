require_relative "../../test_helper"

class GrammarEntryTest < ActiveSupport::TestCase
  test "distinguishes character hubs from child function articles" do
    hub = Grammar::Entry.new(
      "id" => "fw-u4e4b",
      "kind" => "function_word",
      "headword" => "之",
      "title" => "之",
      "path" => "function_words/之/index.md"
    )
    use = Grammar::Entry.new(
      "id" => "fw-u4e4b-attributive",
      "kind" => "function",
      "headword" => "之",
      "title" => "Attributive and possessive 之",
      "path" => "function_words/之/functions/attributive.md",
      "parent" => "fw-u4e4b"
    )

    assert hub.single_character?
    assert use.single_character?
    assert hub.character_hub?
    refute use.character_hub?
  end
end
