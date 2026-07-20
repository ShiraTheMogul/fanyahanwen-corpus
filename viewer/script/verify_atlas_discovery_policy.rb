# frozen_string_literal: true

module AtlasDiscoveryPolicyVerifier
  module_function

  def verify!
    manifest = CorpusSearch::Manifest.load
    directory_index = CorpusSearch::DirectoryIndex.load_or_build
    periodisation = Atlas::Periodisation.default
    catalogue = Atlas::Catalogue.default

    expected = Atlas::PolityDiscovery.new(periodisation: periodisation).merge(
      source_entries: [],
      documents: manifest.documents,
      directory_paths: directory_index.paths
    ).entries

    errors = []
    expected.each do |row|
      root = row.dig("corpus", "root").to_s
      polity = row.dig("corpus", "polity").to_s
      placement_period_id = row.dig("atlas", "placement_period_id").to_s.presence
      expected_periods = Array(row.dig("atlas", "period_ids")).map(&:to_s)
      entry = catalogue.entries.find do |candidate|
        next false unless candidate.corpus_root == root
        next false unless candidate.polities.include?(polity)

        placement_period_id.blank? || candidate.periods.include?(placement_period_id)
      end
      unless entry
        placement = placement_period_id.present? ? " / #{placement_period_id}" : ""
        errors << "Missing discovered polity #{root}#{placement} / #{polity}"
        next
      end

      expected_periods.map(&:to_s).uniq.each do |period_id|
        next if entry.periods.include?(period_id)
        errors << "#{polity} is missing from period #{period_id}"
      end
    end

    catalogue.entries.each do |entry|
      entry.aliases.each do |value|
        if value.include?("--") || value.include?("/") || value.include?("\\")
          errors << "Technical alias is publicly visible for #{entry.id}: #{value}"
        end
      end
    end

    raise errors.first(200).join("\n") if errors.any?

    puts "Atlas discovery-policy verification passed."
    puts "Expected represented polities checked: #{expected.length}."
    true
  end
end

AtlasDiscoveryPolicyVerifier.verify! if $PROGRAM_NAME == __FILE__
