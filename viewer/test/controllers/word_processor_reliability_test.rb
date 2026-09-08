# frozen_string_literal: true

require_relative "../test_helper"

class WordProcessorReliabilityTest < ActionDispatch::IntegrationTest
  test "Writer exposes character-standard runtime failure as service unavailable" do
    failure = CharacterStandards::ConversionUnavailable.new("OpenCC test failure")

    CharacterStandards.stub(:convert, ->(*) { raise failure }) do
      post word_processor_convert_path,
           params: { operation: "script", mode: "traditional", text: "区" },
           as: :json
    end

    assert_response :service_unavailable
    body = response.parsed_body
    assert_equal false, body["ok"]
    assert_equal "OpenCC test failure", body["error"]
  end
  test "Writer date conversion accepts a pre-1000 ISO-like year" do
    post word_processor_convert_path,
         params: { operation: "date", input: "618-06-18", output: "gregorian" },
         as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["ok"], body.inspect
    assert_equal 618, body.dig("result", "year")
  end

  test "Writer Simplified endpoint changes the reported Traditional sample" do
    source = "倉頡作書，告黃帝曰：光光𡆠燿。𡆠椻𪫞𝍭〇𝍰𝍨含〜〜\n"
    post word_processor_convert_path,
         params: { operation: "script", mode: "simplified", text: source },
         as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["ok"], body.inspect
    assert_includes body["text"], "仓颉作书"
    assert_includes body["text"], "告黄帝曰"
    refute_equal source, body["text"]
  end

end
