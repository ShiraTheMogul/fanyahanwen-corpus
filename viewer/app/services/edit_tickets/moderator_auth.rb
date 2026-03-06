module EditTickets
  class ModeratorAuth
    # Header: X-Mod-Token: <token>
    HEADER_NAME = "HTTP_X_MOD_TOKEN".freeze

    def self.authenticate!(request)
      token = request.get_header(HEADER_NAME).to_s
      return nil if token.blank?

      digest = digest(token)
      record = TicketModeratorToken.find_by(token_digest: digest)
      return nil if record.nil? || record.revoked?

      record.update!(last_used_at: Time.current)
      record
    end

    def self.digest(token)
      secret = Rails.application.secret_key_base
      OpenSSL::HMAC.hexdigest("SHA256", secret, "mod:#{token}")
    end
  end
end
