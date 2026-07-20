# frozen_string_literal: true

require "json"
require "pathname"
require "set"

module AtlasTypedSourceVerifier
  module_function

  def verify!(repo_root)
    root = Pathname.new(repo_root)
    atlas_root = root.join("content", "atlas")
    entries_root = atlas_root.join("entries")
    periods_root = atlas_root.join("periods")
    periodisation_path = atlas_root.join("periodisation.json")

    errors = []
    entry_paths = Dir.glob(entries_root.join("*", "metadata.json").to_s).sort
    period_paths = Dir.glob(periods_root.join("**", "metadata.json").to_s).sort
    errors << "No Atlas polity sources were found" if entry_paths.empty?
    errors << "No typed Atlas period sources were found" if period_paths.empty?

    entry_ids = Set.new
    entry_rows = []
    entry_paths.each do |filename|
      path = Pathname.new(filename.dup.force_encoding(Encoding::UTF_8))
      metadata = read_json(path, errors)
      next unless metadata
      id = metadata["id"].to_s
      errors << "Missing polity ID: #{path}" if id.empty?
      errors << "Duplicate polity ID: #{id}" if entry_ids.include?(id)
      entry_ids << id
      errors << "Non-polity record under entries/: #{path}" unless metadata.fetch("kind", "polity") == "polity"
      expected = metadata.dig("corpus", "polity").to_s
      if !expected.empty? && path.dirname.basename.to_s != expected
        errors << "Polity folder/metadata mismatch: #{path.dirname.basename} != #{expected}"
      end
      expected_article = "entries/#{path.dirname.basename}/index.md"
      errors << "Wrong polity article_path in #{path}" unless metadata["article_path"].to_s == expected_article
      Array(metadata.dig("name", "alt")).each do |value|
        alias_value = value.to_s
        if alias_value.include?("--") || alias_value.include?("/") || alias_value.include?("\\")
          errors << "Technical path/ID exposed as a public alias in #{path}: #{alias_value}"
        end
      end
      entry_rows << metadata.merge("_path" => path.to_s)
    end

    period_rows = []
    period_paths.each do |filename|
      path = Pathname.new(filename.dup.force_encoding(Encoding::UTF_8))
      metadata = read_json(path, errors)
      next unless metadata
      id = metadata["id"].to_s
      region = metadata["macro_region"].to_s
      errors << "Period folder/ID mismatch: #{path}" unless path.dirname.basename.to_s == id
      errors << "Missing period macro-region: #{path}" if region.empty?
      errors << "Invalid period kind in #{path}" unless %w[period period_group].include?(metadata.fetch("kind", "period"))
      period_rows << metadata.merge("_path" => path.to_s)
    end

    public_period_terms = period_rows.flat_map do |row|
      [row["id"], row["label"], *Array(row["manifest_periods"])]
    end.compact.map(&:to_s).to_set
    entry_rows.each do |row|
      Array(row.dig("name", "alt")).each do |value|
        if public_period_terms.include?(value.to_s) || Array(row.dig("corpus", "periods")).map(&:to_s).include?(value.to_s)
          errors << "Period label exposed as a polity alias in #{row['_path']}: #{value}"
        end
      end
    end

    period_keys = period_rows.map { |row| [row["macro_region"].to_s, row["id"].to_s] }
    duplicates = period_keys.group_by(&:itself).select { |_key, rows| rows.length > 1 }.keys
    errors.concat(duplicates.map { |key| "Duplicate period key: #{key.join(' / ')}" })
    period_key_set = period_keys.to_set
    period_rows.each do |row|
      parent = row["parent_id"].to_s
      next if parent.empty?
      key = [row["macro_region"].to_s, parent]
      errors << "Missing parent #{key.join(' / ')} for #{row['_path']}" unless period_key_set.include?(key)
    end

    periodisation = read_json(periodisation_path, errors)
    if periodisation
      errors << "periodisation.json must be version 2" unless periodisation["version"].to_i == 2
      Array(periodisation["macro_regions"]).each do |region|
        id = region["id"].to_s
        errors << "Macro-region still contains 漢文: #{id}" if id.include?("漢文")
        Array(region["period_ids"]).each do |period_id|
          errors << "Missing configured root period #{id} / #{period_id}" unless period_key_set.include?([id, period_id.to_s])
        end
        Array(region["corpus_roots"]).each do |corpus_root|
          # Corpus roots deliberately retain 漢文.
          errors << "Empty corpus root for macro-region #{id}" if corpus_root.to_s.empty?
        end
      end
    end

    errors.concat(unicode_errors(atlas_root))
    raise errors.join("\n") if errors.any?

    puts "Typed Atlas source verification passed."
    puts "Polities: #{entry_paths.length}; periods/subperiods: #{period_paths.length}."
    true
  end

  def read_json(path, errors)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    unless raw.valid_encoding?
      errors << "Invalid UTF-8 JSON: #{path}"
      return nil
    end
    parsed = JSON.parse(raw)
    unless parsed.is_a?(Hash)
      errors << "JSON root is not an object: #{path}"
      return nil
    end
    parsed
  rescue Errno::ENOENT
    errors << "Missing JSON file: #{path}"
    nil
  rescue JSON::ParserError => error
    errors << "Invalid JSON in #{path}: #{error.message}"
    nil
  end

  def unicode_errors(root)
    errors = []
    root.find do |path|
      relative = path.relative_path_from(root).to_s.dup.force_encoding(Encoding::UTF_8)
      unless relative.valid_encoding?
        errors << "Invalid UTF-8 path bytes under #{root}"
        next
      end
      errors << "Replacement character in path: #{relative}" if relative.include?("\uFFFD")
      next unless path.file? && %w[.json .md].include?(path.extname.downcase)
      raw = path.binread.force_encoding(Encoding::UTF_8)
      errors << "Invalid UTF-8: #{path}" unless raw.valid_encoding?
      errors << "Replacement character in text: #{path}" if raw.include?("\uFFFD")
    end
    errors
  end
end

AtlasTypedSourceVerifier.verify!(ARGV.first || Dir.pwd) if $PROGRAM_NAME == __FILE__
