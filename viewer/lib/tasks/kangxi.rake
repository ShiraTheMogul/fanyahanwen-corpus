# frozen_string_literal: true

namespace :kangxi do
  desc "Rebuild CharacterRadicalMembership from Unihan kRSUnicode"
  task rebuild_memberships: :environment do
    puts "[kangxi] Rebuilding memberships from Unihan kRSUnicode..."
    before = CharacterRadicalMembership.count
    KangxiRadicals::MembershipBuilder.rebuild!
    after = CharacterRadicalMembership.count
    puts "[kangxi] Done. Rows before=#{before} after=#{after}"
  end
end
