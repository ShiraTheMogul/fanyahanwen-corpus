module EditTickets
  class ModeratorAuth
    # Header: X-Mod-Token: <token>
    HEADER_NAME = "HTTP_X_MOD_TOKEN".freeze

    # Returns a TicketModeratorToken record if:
    # - the header is present
    # - the token exists and is not revoked
    # - the token scope covers at least one of the required scopes (unless required scopes are empty)
    #
    # NOTE: This method is intentionally "soft": it returns nil rather than raising,
    # so controllers can decide whether moderator auth is optional or required.
    def self.verify(request, scopes: [])
      token = request.get_header(HEADER_NAME).to_s
      return nil if token.blank?

      digest = digest(token)
      record = TicketModeratorToken.find_by(token_digest: digest)
      return nil if record.nil? || record.revoked?

      scopes = Array(scopes).map(&:to_s).reject(&:blank?).uniq
      return record if scopes.empty? # any valid moderator token is accepted

      # "admin" is a super-scope that covers everything.
      return record if record.scope.to_s == "admin"
      return record if scopes.include?(record.scope.to_s)

      nil
    end

    def self.digest(token)
      Digest::SHA256.hexdigest(token.to_s)
    end
  end
end
