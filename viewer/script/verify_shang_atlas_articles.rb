# frozen_string_literal: true
# encoding: UTF-8

require "digest"
require "json"
require "pathname"

module ShangAtlasArticleVerifier
  module_function

  PERIOD = "商殷朝"
  CUSTOM_ARTICLE_IDS = %w[shang chong].freeze
  GENERATED_MARKER = "<!-- atlas-generated: shang-polity-inventory-v2 -->"
  BANNED_TEXT = [
    "represented in the corpus’s Shang-period folderisation",
    "The research inventory dates or describes it as:",
    "The inventory classifies",
    "The research inventory lists",
    "## Relationship with Shang",
    "## Attestation"
  ].freeze
  BANNED_ATTESTATIONS = [
    "Book of Poetry (Chang Fa (長發)",
    "Oracle bones |}",
    "Oracle bones as an Earl",
    "Oracle bones through a Marquess name"
  ].freeze

  def verify!(root = Pathname.pwd, io: $stdout)
    root = Pathname.new(root).expand_path
    entries_root = root.join("content", "atlas", "entries")
    errors = []

    records = entries_root.glob("*/metadata.json").filter_map do |metadata_path|
      begin
        metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
        next unless Array(metadata.dig("corpus", "periods")).include?(PERIOD)

        [metadata_path, metadata]
      rescue StandardError => error
        errors << "#{relative(metadata_path, root)}: #{error.class}: #{error.message}"
        nil
      end
    end

    errors << "Expected 53 Shang-period polity records; found #{records.length}" unless records.length == 53

    records.each do |metadata_path, metadata|
      article_path = metadata_path.dirname.join("index.md")
      unless article_path.file?
        errors << "#{relative(article_path, root)}: article is missing"
        next
      end

      body = article_body(article_path.read(encoding: "UTF-8"))
      BANNED_TEXT.each do |phrase|
        errors << "#{relative(article_path, root)}: contains banned generated wording #{phrase.inspect}" if body.include?(phrase)
      end

      unless CUSTOM_ARTICLE_IDS.include?(metadata.fetch("id"))
        errors << "#{relative(article_path, root)}: generated marker is missing" unless body.include?(GENERATED_MARKER)
        errors << "#{relative(article_path, root)}: Overview section is missing" unless body.include?("## Overview")
        errors << "#{relative(article_path, root)}: References section is missing" unless body.include?("## References")

        if metadata.dig("historical", "relationship_with_shang").to_s != "" || special_history?(metadata)
          errors << "#{relative(article_path, root)}: History section is missing" unless body.include?("## History")
        end

        if metadata.dig("locations", "territory_note").to_s != ""
          errors << "#{relative(article_path, root)}: Geography section is missing" unless body.include?("## Geography")
        end
      end

      attestations = Array(metadata.dig("historical", "attested_in")).map(&:to_s)
      BANNED_ATTESTATIONS.each do |value|
        errors << "#{relative(metadata_path, root)}: malformed attestation #{value.inspect}" if attestations.include?(value)
      end

      territory = metadata.dig("locations", "territory_note").to_s
      errors << "#{relative(metadata_path, root)}: duplicated wording in location" if territory.include?("to be to be")
      errors << "#{relative(metadata_path, root)}: unmatched closing parenthesis in location" if territory.end_with?("))")
    end

    verify_presentation!(root, errors)
    verify_oracular_coverage!(root, records, errors)

    unless errors.empty?
      raise <<~MESSAGE
        Shang atlas article verification failed:
        #{errors.map { |error| "  - #{error}" }.join("\n")}
      MESSAGE
    end

    io.puts "Shang atlas article verification passed (#{records.length} polities)."
    true
  end

  def verify_presentation!(root, errors)
    show_path = root.join("app", "views", "atlas", "show.html.erb")
    index_path = root.join("app", "views", "atlas", "index.html.erb")
    locale_path = root.join("config", "locales", "en", "atlas.yml")
    css_path = root.join("app", "assets", "stylesheets", "atlas.css")
    show_view = show_path.read(encoding: "UTF-8")
    index_view = index_path.read(encoding: "UTF-8")
    locale = locale_path.read(encoding: "UTF-8")
    css = css_path.read(encoding: "UTF-8")

    {
      "large regular-script display" => "atlas-script-sample--regular",
      "seal-script display" => "atlas-script-glyph--seal",
      "oracle-bone display" => "atlas-script-glyph--oracle",
      "seal font lookup" => "HanFonts.family_for(:chongxi_seal)",
      "oracle font lookup" => "HanFonts.family_for(:oracular)",
      "Shang-only oracle coverage guard" => "@entry.periods.include?(\"商殷朝\") && HanFonts.covers_text?(:oracular, @entry.hanzi)"
    }.each do |label, token|
      errors << "#{relative(show_path, root)}: #{label} is missing" unless show_view.include?(token)
    end

    ["@entry.relationship_with_shang", "@entry.attested_in"].each do |token|
      errors << "#{relative(show_path, root)}: prominent Shang relationship/attestation field remains (#{token})" if show_view.include?(token)
    end

    if index_view.include?("relationship_with_shang") || index_view.include?("atlas-polity-card-context")
      errors << "#{relative(index_path, root)}: Shang relationship remains on polity listing cards"
    end

    errors << "#{relative(show_path, root)}: generic Atlas data heading remains" if show_view.include?('t("atlas.metadata.heading")')
    errors << "#{relative(locale_path, root)}: 'Atlas data' wording remains" if locale.include?("heading: Atlas data")
    errors << "#{relative(locale_path, root)}: oracle-bone label is missing" unless locale.include?("oracle: Oracle-bone script")

    {
      "regular form spans the row" => ".atlas-script-sample--regular",
      "historical forms use two columns" => "grid-template-columns: repeat(2, minmax(0, 1fr))",
      "single historical form expands" => ".atlas-script-display:not(.atlas-script-display--with-oracle)"
    }.each do |label, token|
      errors << "#{relative(css_path, root)}: #{label} is missing" unless css.include?(token)
    end
  end

  def verify_oracular_coverage!(root, records, errors)
    coverage_path = root.join("app", "assets", "fonts", "oracular", "coverage.json")
    unless coverage_path.file?
      errors << "#{relative(coverage_path, root)}: coverage sidecar is missing"
      return
    end

    payload = JSON.parse(coverage_path.read(encoding: "UTF-8"))
    font_path = coverage_path.dirname.join(payload.fetch("font_file"))
    unless font_path.file?
      errors << "#{relative(font_path, root)}: covered font file is missing"
      return
    end

    digest = Digest::SHA256.file(font_path).hexdigest
    if digest != payload.fetch("font_sha256")
      errors << "#{relative(coverage_path, root)}: coverage digest does not match the webfont"
    end

    codepoints = Array(payload.fetch("codepoints")).map { |value| Integer(value) }
    errors << "#{relative(coverage_path, root)}: duplicate codepoints" unless codepoints.uniq.length == codepoints.length
    errors << "#{relative(coverage_path, root)}: implausibly small coverage list" if codepoints.length < 100

    coverage = codepoints.to_h { |codepoint| [codepoint, true] }
    available = records.count do |_path, metadata|
      han = metadata.dig("name", "hanzi").to_s.each_char.select { |character| character.match?(/\p{Han}/) }
      han.any? && han.all? { |character| coverage.key?(character.ord) }
    end

    errors << "Oracular coverage should be available for some, but not all, Shang names; found #{available} of #{records.length}" unless available.between?(1, records.length - 1)
  rescue JSON::ParserError, KeyError, ArgumentError => error
    errors << "#{relative(coverage_path, root)}: #{error.class}: #{error.message}"
  end

  def special_history?(metadata)
    [
      "Early to middle Shang dynasty, conquered by Wu Ding",
      "Middle to late Shang dynasty, overthrew Di Xin and established the Zhou dynasty."
    ].include?(metadata.dig("historical", "period_description").to_s)
  end

  def article_body(raw)
    lines = raw.lines
    return raw unless lines.first&.strip == "---"

    closing = lines.each_index.drop(1).find { |index| lines[index].strip == "---" }
    closing ? lines[(closing + 1)..].join : raw
  end

  def relative(path, root)
    Pathname.new(path).relative_path_from(root).to_s
  end
end

if $PROGRAM_NAME == __FILE__
  root = ARGV.fetch(0, Pathname.new(__dir__).join("..").expand_path.to_s)
  ShangAtlasArticleVerifier.verify!(root)
end
