require_relative "../../test_helper"

class CorpusSearchClientIdentityTest < ActiveSupport::TestCase
  test "builds HMAC client keys without storing raw identifiers" do
    identity = CorpusSearch::ClientIdentity.new(
      ip_address: "203.0.113.9",
      cookie_token: "browser-token"
    )

    assert_match(/\A[0-9a-f]{64}\z/, identity.ip_key)
    assert_match(/\A[0-9a-f]{64}\z/, identity.cookie_key)
    assert_not_includes identity.ip_key, "203.0.113.9"
    assert_not_includes identity.cookie_key, "browser-token"
    assert_equal({ "ip_key" => identity.ip_key, "cookie_key" => identity.cookie_key }, identity.to_h)
  end

  test "email keys are case-insensitive HMACs" do
    lower = CorpusSearch::ClientIdentity.email_key("researcher@example.org")
    mixed = CorpusSearch::ClientIdentity.email_key(" Researcher@Example.Org ")

    assert_equal lower, mixed
    assert_match(/\A[0-9a-f]{64}\z/, lower)
    assert_not_includes lower, "researcher@example.org"
    assert_nil CorpusSearch::ClientIdentity.email_key("")
  end

  test "notification email encryption round trips and rejects invalid ciphertext" do
    ciphertext = CorpusSearch::ClientIdentity.encrypt_email("reader@example.org")

    assert_not_equal "reader@example.org", ciphertext
    assert_equal "reader@example.org", CorpusSearch::ClientIdentity.decrypt_email(ciphertext)
    assert_nil CorpusSearch::ClientIdentity.decrypt_email("not-valid-ciphertext")
    assert_nil CorpusSearch::ClientIdentity.encrypt_email("")
  end
end
