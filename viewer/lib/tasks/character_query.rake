# frozen_string_literal: true

namespace :character_query do
  desc "Pre-warm slot indexes. Optional: they build lazily on first query. " \
       "Usage: bin/rails character_query:warm SYSTEMS=mandarin,cantonese"
  task warm: :environment do
    requested = ENV["SYSTEMS"].to_s.split(",").map(&:strip).reject(&:empty?)
    systems = requested.presence || CharacterQuery::ReadingSystem::DEFINITIONS.keys

    systems.each do |system|
      next unless CharacterQuery::ReadingSystem.known?(system)

      started = Time.current
      begin
        coverage = CharacterQuery::SlotIndex.coverage(system)
        puts format("[character_query] %-22s %5d slots  %6d characters  %.1fs",
                    system, coverage[:slot_count], coverage[:character_count],
                    Time.current - started)
      rescue CharacterQuery::SlotIndex::Unsupported => error
        puts "[character_query] #{system}: skipped (#{error.message})"
      end
    end
  end

  desc "Delete cached slot indexes. Usage: bin/rails character_query:clear [SYSTEM=mandarin]"
  task clear: :environment do
    CharacterQuery::SlotIndex.clear!(ENV["SYSTEM"].presence)
    puts "[character_query] cleared #{ENV['SYSTEM'].presence || 'all slot indexes'}"
  end
end
