namespace :edit_tickets do
  desc "Purge expired / closed ticket contacts (privacy)"
  task purge_contacts: :environment do
    PurgeExpiredTicketContactsJob.perform_now
    puts "Done."
  end

  desc "Create a moderator token (shows plaintext once)"
  task :issue_moderator_token, %i[scope name] => :environment do |_, args|
    scope = args[:scope].to_s
    name = args[:name].to_s

    if scope.blank? || name.blank?
      abort "Usage: rake edit_tickets:issue_moderator_token['admin','Llinos (maintainer)']"
    end

    unless TicketModeratorToken::SCOPES.include?(scope)
      abort "Invalid scope. Allowed: #{TicketModeratorToken::SCOPES.join(', ')}"
    end

    record, plaintext = EditTickets::ModeratorTokenIssuer.issue!(name: name, scope: scope)

    puts "Created moderator token id=#{record.id} name=#{record.name} scope=#{record.scope}"
    puts "PLAINTEXT TOKEN (shown once): #{plaintext}"
  end
end

namespace :edit_tickets do
  desc "Create a SQLite backup of the primary database with ticket contact rows removed"
  task :privacy_safe_backup, [:destination] => :environment do |_, args|
    require "fileutils"
    require "sqlite3"

    destination = args[:destination].to_s.strip
    abort "Usage: bin/rails edit_tickets:privacy_safe_backup[/path/to/backup.sqlite3]" if destination.blank?

    source = ActiveRecord::Base.connection_db_config.database.to_s
    source_path = Pathname.new(source)
    source_path = Rails.root.join(source_path) unless source_path.absolute?
    source_path = source_path.expand_path
    destination_path = Pathname.new(destination).expand_path

    abort "Primary database not found: #{source_path}" unless source_path.file?
    abort "Destination must not be the live database" if destination_path == source_path

    FileUtils.mkdir_p(destination_path.dirname)
    FileUtils.rm_f(destination_path)

    source_db = SQLite3::Database.new(source_path.to_s)
    destination_db = SQLite3::Database.new(destination_path.to_s)
    backup = SQLite3::Backup.new(destination_db, "main", source_db, "main")

    begin
      backup.step(-1)
    ensure
      backup.finish
      source_db.close
    end

    begin
      destination_db.execute("DELETE FROM ticket_contacts")
      destination_db.execute("VACUUM")
    ensure
      destination_db.close
    end

    puts "Created privacy-safe backup: #{destination_path}"
    puts "ticket_contacts rows were removed from the backup copy."
  end
end
