module EditTickets
  class KeyManager
    KEY_BYTES = 32
    SALT_BYTES = 16

    def self.generate_plaintext
      # URL-safe, copy/paste friendly.
      SecureRandom.urlsafe_base64(KEY_BYTES)
    end

    def self.generate_salt
      SecureRandom.hex(SALT_BYTES)
    end

    def self.digest(plaintext, salt)
      secret = Rails.application.secret_key_base
      data = "#{salt}:#{plaintext}"
      OpenSSL::HMAC.hexdigest("SHA256", secret, data)
    end

    def self.valid?(expected_digest, plaintext, salt)
      actual = digest(plaintext, salt)
      ActiveSupport::SecurityUtils.secure_compare(expected_digest, actual)
    rescue StandardError
      false
    end
  end
end
