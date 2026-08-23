# frozen_string_literal: true

require_relative "../test_helper"

class AuthorsControllerTest < ActionController::TestCase
  tests AuthorsController

  FakeCandidateSet = Struct.new(:candidates)

  class FakeRepository
    def initialize(corpus_profile: nil, candidates: [])
      @corpus_profile = corpus_profile
      @candidates = candidates
    end

    def corpus_profile(_name) = @corpus_profile
    def find_candidates(names:, metadata:) = FakeCandidateSet.new(@candidates)
  end

  test "JSON author payload always provides a search destination when no direct profile resolves" do
    repository = FakeRepository.new

    HistoricalPersonRepository.stub(:new, repository) do
      get :index, params: { name: "孔丘", format: :json }
    end

    assert_response :success
    payload = JSON.parse(response.body)
    match = payload.fetch("matches").first
    assert_equal "孔丘", match.fetch("name")
    assert_not match.key?("profile")
    assert_match(%r{\A/authors\?name=}, match.fetch("search_url"))
  end

  test "JSON author payload prefers the explicit corpus profile when the catalogue resolves it" do
    repository = FakeRepository.new(
      corpus_profile: { "id" => "孔丘", "label" => "孔丘" }
    )

    HistoricalPersonRepository.stub(:new, repository) do
      get :index, params: { name: "孔丘", format: :json }
    end

    assert_response :success
    profile = JSON.parse(response.body).fetch("matches").first.fetch("profile")
    assert_equal "corpus", profile.fetch("source")
    assert_equal "孔丘", profile.fetch("id")
    assert_equal "corpus_credit", profile.fetch("confidence")
  end
end
