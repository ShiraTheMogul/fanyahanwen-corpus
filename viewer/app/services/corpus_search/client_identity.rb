# frozen_string_literal: true

require "openssl"
require "securerandom"

module CorpusSearch
  # Builds short-lived, accountless identifiers for expensive prepared searches.
  #
  # The site never needs user accounts for corpus search. Instead, a full-corpus
  # background job is guarded by two temporary keys:
  #   * an HMAC of the request IP address;
  #   * an HMAC of an anonymous encrypted cookie token.
  #
  # HMAC is used rather than a plain hash because IPv4 addresses are easy to
  # brute-force if a cache file ever leaks. The secret is derived from the Rails
  # secret key base, so the stored key is not useful without server secrets.
  class ClientIdentity
    COOKIE_NAME = :fyhwc_full_search_client
    COOKIE_TTL = 1.year

    attr_reader :ip_key, :cookie_key

    def self.from_request(request:, cookies:)
      token = cookies.encrypted[COOKIE_NAME].to_s
      token = SecureRandom.urlsafe_base64(32) if token.blank?
      cookies.encrypted[COOKIE_NAME] = {
        value: token,
        expires: COOKIE_TTL.from_now,
        same_site: :lax,
        httponly: true
      }

      new(ip_address: request.remote_ip, cookie_token: token)
    end

    def self.hmac(value)
      OpenSSL::HMAC.hexdigest("SHA256", secret, value.to_s)
    end

    def self.email_key(email)
      normalised = email.to_s.strip.downcase
      return nil if normalised.blank?

      hmac("email:#{normalised}")
    end

    def self.encrypt_email(email)
      normalised = email.to_s.strip
      return nil if normalised.blank?

      encryptor.encrypt_and_sign(normalised)
    end

    def self.decrypt_email(ciphertext)
      return nil if ciphertext.blank?

      encryptor.decrypt_and_verify(ciphertext)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    def initialize(ip_address:, cookie_token:)
      @ip_key = self.class.hmac("ip:#{ip_address}") if ip_address.present?
      @cookie_key = self.class.hmac("cookie:#{cookie_token}") if cookie_token.present?
    end

    def to_h
      {
        "ip_key" => ip_key,
        "cookie_key" => cookie_key
      }.compact
    end

    private_class_method def self.secret
      Rails.application.key_generator.generate_key("corpus-search-client-identity", 32)
    end

    private_class_method def self.encryptor
      key = Rails.application.key_generator.generate_key("corpus-search-email-notification", ActiveSupport::MessageEncryptor.key_len)
      ActiveSupport::MessageEncryptor.new(key)
    end
  end
end
