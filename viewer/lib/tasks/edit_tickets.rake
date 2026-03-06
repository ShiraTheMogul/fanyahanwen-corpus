namespace :edit_tickets do
  desc "Purge expired / closed ticket contacts (privacy)"
  task purge_contacts: :environment do
    PurgeExpiredTicketContactsJob.perform_now
    puts "Done."
  end

  desc "Create a moderator token (shows plaintext once)"
  task :issue_moderator_token, %i[name scope] => :environment do |_, args|
    name = args[:name].to_s
    scope = args[:scope].to_s

    if name.blank?
      abort "Usage: rake edit_tickets:issue_moderator_token['Name','review_only']"
    end

    unless TicketModeratorToken::SCOPES.include?(scope)
      abort "Invalid scope. Allowed: #{TicketModeratorToken::SCOPES.join(', ')}"
    end

    record, plaintext = EditTickets::ModeratorTokenIssuer.issue!(name: name, scope: scope)

    puts "Created moderator token id=#{record.id} name=#{record.name} scope=#{record.scope}"
    puts "PLAINTEXT TOKEN (shown once): #{plaintext}"
  end
end
