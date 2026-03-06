module EditTickets
  class ModeratorTokenIssuer
    TOKEN_BYTES = 32

    def self.issue!(name:, scope:)
      plaintext = SecureRandom.urlsafe_base64(TOKEN_BYTES)
      digest = ModeratorAuth.digest(plaintext)
      record = TicketModeratorToken.create!(
        name: name,
        scope: scope,
        token_digest: digest
      )
      [record, plaintext]
    end
  end
end
