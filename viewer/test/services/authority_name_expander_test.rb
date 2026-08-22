# frozen_string_literal: true

require_relative "../test_helper"
require "set"

class AuthorityNameExpanderTest < ActiveSupport::TestCase
  FakeRegistry = Struct.new(:forms, :sources) do
    def forms_for(character)
      Set.new(forms.fetch(character, [character]))
    end

    def explanation(query_character:, source_character:)
      {
        "mapping_sources" => Array(sources[[query_character, source_character]])
      }
    end
  end

  test "OpenCC and shinjitai substitutions may combine across a name" do
    registry = FakeRegistry.new(
      { "國" => %w[國 国], "德" => %w[德 徳] },
      {
        ["國", "国"] => ["opencc_simplified_traditional"],
        ["德", "徳"] => ["opencc_japanese_shinjitai"]
      }
    )
    forms = AuthorityNameExpander.new(registry: registry).expand("國德").map(&:name)

    assert_includes forms, "国德"
    assert_includes forms, "國徳"
    assert_includes forms, "国徳"
  end

  test "broad historical variants are retained singly but not multiplied cartesianly" do
    registry = FakeRegistry.new(
      { "國" => %w[國 国], "歷" => %w[歷 厯] },
      {
        ["國", "国"] => ["opencc_simplified_traditional"],
        ["歷", "厯"] => ["taiwan_moe"]
      }
    )
    forms = AuthorityNameExpander.new(registry: registry).expand("國歷").map(&:name)

    assert_includes forms, "国歷"
    assert_includes forms, "國厯"
    refute_includes forms, "国厯"
  end
end
