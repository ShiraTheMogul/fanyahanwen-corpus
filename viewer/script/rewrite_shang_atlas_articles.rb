#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8

require "json"
require "pathname"
require "tempfile"

module ShangAtlasArticleRewriter
  module_function

  PERIOD = "商殷朝"
  CUSTOM_ARTICLE_IDS = %w[shang chong].freeze
  GENERATED_MARKER = "<!-- atlas-generated: shang-polity-inventory-v2 -->"

  ATTESTATION_FIXES = {
    "Book of Poetry (Chang Fa (長發)" => "Book of Poetry, ‘Chang Fa’ (長發)",
    "Oracle bones |}" => "Oracle bones",
    "Oracle bones as an Earl" => "Oracle-bone inscriptions naming an earl",
    "Oracle bones through a Marquess name" => "Oracle-bone inscriptions naming a marquess"
  }.freeze

  TERRITORY_FIXES = {
    "Southeast of Yin, coast of the Donghai (present Huai River basin and coast of the Yellow Sea at the Shandong Peninsula, northern Anhui and southern Shandong))" =>
      "Southeast of Yin, on the coast of the Donghai (present Huai River basin, Shandong Peninsula, northern Anhui, and southern Shandong)",
    "Sichuan Province, also argued to be to be southern Shaanxi or Jianghan" =>
      "Sichuan; southern Shaanxi and the Jianghan region have also been proposed",
    "Sichuan Province" => "Sichuan",
    "West of Yin (present south of Shanxi Province)" =>
      "West of Yin, in present-day southern Shanxi",
    "West of Yin (Shanxi-Shaanxi Plateau); arguments are made for the east." =>
      "West of Yin on the Shanxi–Shaanxi Plateau; an eastern location has also been proposed",
    "West of Yin (Shanxi-Shaanxi Plateau); arguments are made for an eastern location." =>
      "West of Yin on the Shanxi–Shaanxi Plateau; an eastern location has also been proposed",
    "Northwest of Yin (present Shaanxi Province, the area around Gansu Province, Shanxi-Shaanxi Plateau)" =>
      "Northwest of Yin, across parts of present-day Shaanxi and Gansu on the Shanxi–Shaanxi Plateau",
    "Northwest of Yin, west of Tu Fang (north of present Shaanxi Province, Shanxi-Shaanxi Plateau)" =>
      "Northwest of Yin and west of Tufang, in the northern part of present-day Shaanxi on the Shanxi–Shaanxi Plateau",
    "Northwest of Yin (present central Shanxi Province and northern Shaanxi province, Shanxi-Shaanxi Plateau)" =>
      "Northwest of Yin, in present-day central Shanxi and northern Shaanxi on the Shanxi–Shaanxi Plateau"
  }.freeze

  def run!(root, apply: false, force: false, io: $stdout)
    root = Pathname.new(root).expand_path
    entries_root = root.join("content", "atlas", "entries")
    catalogue_path = root.join("content", "atlas", "catalogue-v2.json")

    records = entries_root.glob("*/metadata.json").filter_map do |metadata_path|
      metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
      next unless Array(metadata.dig("corpus", "periods")).include?(PERIOD)

      [metadata_path, metadata]
    end

    raise "Expected 53 Shang-period polity records; found #{records.length}" unless records.length == 53

    changed_metadata = 0
    changed_articles = 0
    skipped_custom = []

    records.each do |metadata_path, metadata|
      normalized = normalize_metadata(metadata)
      if normalized != metadata
        changed_metadata += 1
        atomic_write(metadata_path, pretty_json(normalized)) if apply
      end

      if CUSTOM_ARTICLE_IDS.include?(normalized.fetch("id"))
        skipped_custom << normalized.fetch("id")
        next
      end

      article_path = metadata_path.dirname.join("index.md")
      raise "Missing article: #{article_path}" unless article_path.file?

      raw = article_path.read(encoding: "UTF-8")
      front_matter, old_body = split_front_matter(raw)

      unless force || old_body.include?(GENERATED_MARKER) || generated_v1_body?(old_body)
        raise "Refusing to overwrite a manually edited article: #{article_path}"
      end

      new_body = build_body(normalized)
      next if old_body == new_body

      changed_articles += 1
      atomic_write(article_path, front_matter + new_body) if apply
    end

    if catalogue_path.file?
      catalogue = JSON.parse(catalogue_path.read(encoding: "UTF-8"))
      metadata_by_id = records.to_h { |_path, metadata| [metadata.fetch("id"), normalize_metadata(metadata)] }
      catalogue.fetch("entries").map! do |entry|
        replacement = metadata_by_id[entry["id"]]
        next entry unless replacement

        entry.merge(
          "locations" => replacement.fetch("locations"),
          "historical" => replacement.fetch("historical")
        )
      end
      atomic_write(catalogue_path, pretty_json(catalogue)) if apply
    end

    mode = apply ? "Applied" : "Would apply"
    io.puts "#{mode} the Shang atlas prose rewrite."
    io.puts "Shang-period polities checked: #{records.length}"
    io.puts "Generated articles changed: #{changed_articles}"
    io.puts "Metadata records normalized: #{changed_metadata}"
    io.puts "Full articles preserved: #{skipped_custom.join(', ')}"

    { records: records.length, articles: changed_articles, metadata: changed_metadata }
  end

  def normalize_metadata(metadata)
    normalized = deep_copy(metadata)

    historical = normalized["historical"] ||= {}
    historical["attested_in"] = Array(historical["attested_in"]).map do |value|
      ATTESTATION_FIXES.fetch(value.to_s, value.to_s)
    end

    locations = normalized["locations"] ||= {}
    territory = locations["territory_note"].to_s.strip
    locations["territory_note"] = TERRITORY_FIXES.fetch(territory, territory)

    normalized
  end

  def build_body(metadata)
    historical = metadata.fetch("historical", {})
    sections = []

    sections << GENERATED_MARKER
    sections << ""
    sections << "## Overview"
    sections << ""
    sections << overview_sentence(metadata)

    history = history_paragraph(metadata)
    if history
      sections << ""
      sections << "## History"
      sections << ""
      sections << history
    end

    geography = geography_sentence(metadata.dig("locations", "territory_note"))
    if geography
      sections << ""
      sections << "## Geography"
      sections << ""
      sections << geography
    end

    references = Array(historical["references"]).map(&:to_s).reject(&:empty?)
    unless references.empty?
      sections << ""
      sections << "## References"
      sections << ""
      references.each { |reference| sections << "- #{reference}" }
    end

    "\n" + sections.join("\n") + "\n"
  end

  def overview_sentence(metadata)
    name = display_name(metadata)
    period = period_phrase(metadata.dig("historical", "period_description"))
    sources = source_phrase(Array(metadata.dig("historical", "attested_in")))

    sentence = "#{name} was a polity #{period}"
    return sentence + "." unless sources

    if period.include?(",")
      "#{sentence}. It is #{sources}."
    else
      "#{sentence}, #{sources}."
    end
  end

  def display_name(metadata)
    display = metadata.dig("name", "display").to_s
    hanzi = metadata.dig("name", "hanzi").to_s
    aliases = Array(metadata.dig("name", "alt")).map(&:to_s).reject(&:empty?)
    aliases = aliases.reject { |alias_name| hanzi.include?(alias_name) }

    written_form = hanzi
    written_form += ", also written #{human_join(aliases)}" unless aliases.empty?

    "#{display} (#{written_form})"
  end

  def period_phrase(description)
    case description.to_s.strip
    when "Shang dynasty"
      "during the Shang dynasty"
    when "Early to middle Shang dynasty, conquered by Wu Ding"
      "during the early to middle Shang dynasty"
    when "Middle to late Shang dynasty, overthrew Di Xin and established the Zhou dynasty."
      "from the middle to the late Shang dynasty"
    when "Shang dynasty, to period of Zu Geng"
      "during the Shang dynasty, continuing into the reign of Zu Geng"
    when "Xia dynasty, Shang dynasty"
      "associated in the sources with the Xia and Shang periods"
    else
      description = description.to_s.strip.sub(/\.$/, "")
      description.empty? ? "during the Shang dynasty" : "during #{description.downcase}"
    end
  end

  def source_phrase(values)
    values = values.map(&:to_s).reject(&:empty?).uniq
    return nil if values.empty?

    mentioned = []
    attested = []

    values.each do |value|
      case value
      when "Records of the Grand Historian"
        mentioned << "the *Records of the Grand Historian*"
      when "Bamboo Annals"
        mentioned << "the *Bamboo Annals*"
      when "Book of Poetry"
        mentioned << "the *Book of Poetry*"
      when "Book of Poetry, ‘Chang Fa’ (長發)"
        mentioned << "the ‘Chang Fa’ (長發) ode of the *Book of Poetry*"
      when "Oracle bones"
        attested << "oracle-bone inscriptions"
      when "Bronze inscriptions"
        attested << "bronze inscriptions"
      when "Ritual bronzes"
        attested << "ritual-bronze inscriptions"
      when "Oracle-bone inscriptions naming an earl"
        attested << "oracle-bone inscriptions that name an earl"
      when "Oracle-bone inscriptions naming a marquess"
        attested << "oracle-bone inscriptions that name a marquess"
      else
        attested << value.sub(/\.$/, "")
      end
    end

    clauses = []
    clauses << "mentioned in #{human_join(mentioned)}" unless mentioned.empty?
    clauses << "attested in #{human_join(attested)}" unless attested.empty?
    clauses.join(", and ")
  end

  def history_paragraph(metadata)
    name = metadata.dig("name", "display").to_s
    relationship = metadata.dig("historical", "relationship_with_shang").to_s.strip
    period = metadata.dig("historical", "period_description").to_s.strip

    return "#{name} appears in the sources as an enemy of Shang and was conquered during the reign of King Wu Ding." if period == "Early to middle Shang dynasty, conquered by Wu Ding"

    if period == "Middle to late Shang dynasty, overthrew Di Xin and established the Zhou dynasty."
      return "Relations between #{name} and Shang changed over time. #{name} ultimately overthrew King Di Xin and established the Zhou dynasty."
    end

    case relationship
    when "ally"
      "The surviving sources suggest that #{name} was allied with Shang."
    when "ally?"
      "#{name} may have been allied with Shang, although the evidence is uncertain."
    when "enemy"
      "#{name} appears in the surviving sources as an enemy of Shang."
    when "enemy, suppressed"
      "#{name} appears as an enemy of Shang and was eventually suppressed."
    when "enemy, later conquered"
      "#{name} appears as an enemy of Shang and was later conquered."
    when "swing"
      "Relations between #{name} and Shang appear to have changed over time."
    when ""
      nil
    else
      "The surviving sources describe #{name}’s relations with Shang as #{relationship}."
    end
  end

  def geography_sentence(note)
    note = note.to_s.strip
    return nil if note.empty?
    return "Its precise location is unknown." if note.casecmp("unknown").zero?

    case note
    when "Sichuan; southern Shaanxi and the Jianghan region have also been proposed"
      "It is usually associated with Sichuan, although southern Shaanxi and the Jianghan region have also been proposed."
    when "Sichuan"
      "It was located in Sichuan."
    when "West of Yin on the Shanxi–Shaanxi Plateau; an eastern location has also been proposed"
      "It is usually placed west of Yin on the Shanxi–Shaanxi Plateau, although an eastern location has also been proposed."
    else
      sentence = note.sub(/\Apresent\b/i, "present-day")
      sentence = sentence.sub(/\((present)(?=[^_-])/i, "(present-day")
      sentence = sentence.sub(/\A([A-Z])/) { Regexp.last_match(1).downcase }
      "It was located #{sentence.sub(/\.$/, '')}."
    end
  end

  def human_join(values)
    values = values.compact.map(&:to_s).reject(&:empty?)
    case values.length
    when 0 then ""
    when 1 then values.first
    when 2 then values.join(" and ")
    else "#{values[0...-1].join(', ')}, and #{values.last}"
    end
  end

  def generated_v1_body?(body)
    body.include?("represented in the corpus’s Shang-period folderisation") ||
      body.include?("The research inventory dates or describes it as:")
  end

  def split_front_matter(raw)
    lines = raw.lines
    raise "Article has no YAML front matter" unless lines.first&.strip == "---"

    closing = lines.each_index.drop(1).find { |index| lines[index].strip == "---" }
    raise "Article has unclosed YAML front matter" unless closing

    [lines[0..closing].join, lines[(closing + 1)..].join]
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def pretty_json(value)
    JSON.pretty_generate(value) + "\n"
  end

  def atomic_write(path, content)
    path = Pathname.new(path)
    Tempfile.create([path.basename.to_s, ".tmp"], path.dirname.to_s, encoding: "UTF-8") do |file|
      file.write(content)
      file.flush
      file.fsync
      File.rename(file.path, path.to_s)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = ARGV.find { |argument| !argument.start_with?("--") } || File.expand_path("..", __dir__)
  apply = ARGV.include?("--apply")
  force = ARGV.include?("--force")
  ShangAtlasArticleRewriter.run!(root, apply: apply, force: force)
end
