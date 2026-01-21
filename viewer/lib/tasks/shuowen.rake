# frozen_string_literal: true

namespace :shuowen do
  desc "Seed ShuowenComponent from lib/data/shuowen_components.txt"
  task seed_components: :environment do
    path = Rails.root.join("lib", "data", "shuowen_components.txt")
    puts "[shuowen] Seeding components from #{path}..."
    Shuowen::ComponentSeeder.seed_from_file!(path)
    puts "[shuowen] Done. Components=#{ShuowenComponent.count}"
  end

  desc "Show counts for Shuowen-related CharacterProperty fields"
  task inspect_fields: :environment do
    rows = CharacterProperty
      .where("lower(field) LIKE ?", "%shuowen%")
      .group(:field, :source)
      .order(Arel.sql("COUNT(*) DESC"))
      .count

    if rows.empty?
      puts "[shuowen] No CharacterProperty rows where field contains 'shuowen'."
      puts "[shuowen] This means your Shuowen importer has not been run yet (or used different field names)."
      next
    end

    puts "[shuowen] Shuowen-related field/source counts:"
    rows.each do |(field, source), n|
      puts "  - field=#{field} source=#{source.inspect} count=#{n}"
    end
  end

  desc "Rebuild CharacterComponentMembership from CharacterProperty shuowen_category. Use FIELD=... SOURCE=... to override."
  task rebuild_memberships: :environment do
    puts "[shuowen] Rebuilding memberships from CharacterProperty..."
    before = CharacterComponentMembership.count
    result = Shuowen::MembershipBuilder.rebuild!(field: ENV["FIELD"], source: ENV["SOURCE"])
    after = CharacterComponentMembership.count

    puts "[shuowen] Field=#{result[:field].inspect} source=#{result[:source].inspect} reason=#{result[:reason]} rows=#{result[:rows]}"
    puts "[shuowen] Done. Rows before=#{before} after=#{after}"
  end
end
