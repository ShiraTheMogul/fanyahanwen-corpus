# frozen_string_literal: true

require "digest"
require "json"
require "thread"

# Discover available Han-script fonts from app/assets/fonts and expose them to
# the UI and the dynamic @font-face injector.
#
# A font folder may optionally contain font.json:
# {
#   "label": "LXGW WenKai KR - Regular",
#   "family": "Fanya LXGW WenKai KR Regular",
#   "group": "LXGW WenKai KR",
#   "file": "LXGWWenKaiKR-Regular.ttf"
# }
#
# The metadata keeps display names and related variants together without making
# font choice responsible for character-standard conversion.
module HanFonts
  FONT_EXTS = %w[.woff2 .woff .otf .ttf].freeze
  CREDIT_PATTERNS = ["LICENSE*", "OFL*", "CREDITS*", "README*", "COPYING*"].freeze
  METADATA_FILE = "font.json"

  FontFace = Struct.new(
    :key,
    :label,
    :family,
    :asset_path,
    :format,
    :unicode_range,
    :group,
    keyword_init: true
  )

  module_function

  def choices
    distinct_faces.map { |face| [face.label, face.key] }
                  .sort_by { |label, _| label.downcase }
  end

  # Rails' grouped_options_for_select consumes [group_label, options] pairs.
  # A named group is retained only when it has at least two choices; one-off
  # fonts go into the translated catch-all group supplied by the view.
  def choice_groups(ungrouped_label: "Other fonts")
    entries = distinct_faces.sort_by { |face| [face.group.to_s.downcase, face.label.downcase] }
    by_group = entries.group_by { |face| face.group.to_s.strip.presence }

    grouped = []
    ungrouped = Array(by_group.delete(nil))

    by_group.keys.compact.sort_by(&:downcase).each do |group_name|
      members = by_group.fetch(group_name)
      if members.length < 2
        ungrouped.concat(members)
        next
      end

      grouped << [group_name, members.map { |face| [face.label, face.key] }]
    end

    unless ungrouped.empty?
      grouped.unshift([
        ungrouped_label,
        ungrouped.sort_by { |face| face.label.downcase }.map { |face| [face.label, face.key] }
      ])
    end

    grouped
  end

  def distinct_faces
    faces.group_by(&:key).values.map(&:first)
  end

  def allowed_keys
    faces.map(&:key).uniq
  end

  def default_key
    allowed_keys.include?(:wenjin_mincho) ? :wenjin_mincho : allowed_keys.first
  end

  def family_for(key)
    k = normalise_key(key)
    f = faces.find { |ff| ff.key == k }
    f ? f.family : faces.first&.family
  end

  def stack_for(key)
    fam = family_for(key)
    wen = family_for(:wenjin_mincho) || "serif"

    if fam.to_s == wen.to_s
      %Q{"#{wen}", serif}
    else
      %Q{"#{fam}", "#{wen}", serif}
    end
  end

  def covers_text?(key, text)
    characters = text.to_s.each_char.select { |character| character.match?(/\p{Han}/) }
    return false if characters.empty?

    coverage = coverage_for(key)
    return false if coverage.empty?

    characters.all? { |character| coverage.key?(character.ord) }
  end

  def coverage_for(key)
    normalised = normalise_key(key)
    face = faces.find { |font_face| font_face.key == normalised }
    return {} unless face

    font_path = Rails.root.join("app", "assets", "fonts", face.asset_path)
    coverage_path = font_path.dirname.join("coverage.json")
    return {} unless font_path.file? && coverage_path.file?

    stamp = [font_path.mtime.to_f, coverage_path.mtime.to_f]
    @coverage_cache ||= {}
    cached = @coverage_cache[normalised]
    return cached.fetch(:values) if cached && cached.fetch(:stamp) == stamp

    payload = JSON.parse(coverage_path.read(encoding: "UTF-8"))
    expected_font = payload.fetch("font_file").to_s
    expected_digest = payload.fetch("font_sha256").to_s

    return {} unless expected_font == font_path.basename.to_s
    return {} unless Digest::SHA256.file(font_path).hexdigest == expected_digest

    values = Array(payload.fetch("codepoints")).each_with_object({}) do |codepoint, output|
      output[Integer(codepoint)] = true
    end.freeze

    @coverage_cache[normalised] = { stamp: stamp, values: values }
    values
  rescue JSON::ParserError, KeyError, ArgumentError, Errno::ENOENT
    {}
  end

  def allowed_scopes
    %i[all headwords]
  end

  def default_scope
    :all
  end

  DEVELOPMENT_DISCOVERY_TTL = [ENV.fetch("HAN_FONTS_DISCOVERY_TTL", "30").to_f, 0.0].max

  def faces
    return @faces ||= discover_faces unless defined?(Rails) && Rails.env.development?

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @faces && @faces_discovered_at && DEVELOPMENT_DISCOVERY_TTL.positive? &&
       (now - @faces_discovered_at) < DEVELOPMENT_DISCOVERY_TTL
      return @faces
    end

    (@faces_mutex ||= Mutex.new).synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @faces && @faces_discovered_at && DEVELOPMENT_DISCOVERY_TTL.positive? &&
         (now - @faces_discovered_at) < DEVELOPMENT_DISCOVERY_TTL
        return @faces
      end

      @faces = discover_faces
      @faces_discovered_at = now
    end

    @faces
  end

  def refresh!
    @faces = discover_faces
    @faces_discovered_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @credits_paths = nil
    @coverage_cache = nil
  end

  def normalise_key(value)
    value.to_s.strip.downcase.tr(" ", "_").tr("-", "_").to_sym
  end

  def discover_faces
    root = Rails.root.join("app/assets/fonts")
    return [] unless Dir.exist?(root)

    out = []
    out.concat(wenjin_faces(root))

    Dir.children(root).each do |child|
      next if child.start_with?(".")
      dir = root.join(child)
      next unless Dir.exist?(dir)
      next if child == "wenjin_mincho"

      metadata = font_metadata(dir)
      best = choose_metadata_file(dir, metadata) || choose_best_in_dir(dir)
      next unless best

      rel = Pathname(best).relative_path_from(root).to_s
      key = normalise_key(child)
      label = metadata.fetch("label", human_label(child)).to_s
      family = metadata.fetch("family", label).to_s
      group = metadata["group"].to_s.strip.presence

      out << FontFace.new(
        key: key,
        label: label,
        family: family,
        asset_path: rel,
        format: css_format_for(rel),
        unicode_range: UnicodeRanges.han_css_unicode_range,
        group: group
      )
    end

    Dir.glob(root.join("*")) do |p|
      next unless File.file?(p)
      next unless FONT_EXTS.include?(File.extname(p).downcase)

      rel = Pathname(p).relative_path_from(root).to_s
      base = File.basename(rel, File.extname(rel))
      key = normalise_key(base)
      label = human_label(base)

      out << FontFace.new(
        key: key,
        label: label,
        family: label,
        asset_path: rel,
        format: css_format_for(rel),
        unicode_range: UnicodeRanges.han_css_unicode_range,
        group: nil
      )
    end

    out
  end

  def font_metadata(dir)
    path = dir.join(METADATA_FILE)
    return {} unless path.file?

    text = File.open(path, "r:bom|utf-8", &:read)
    value = JSON.parse(text)
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError, Errno::ENOENT
    {}
  end

  def choose_metadata_file(dir, metadata)
    wanted = metadata["file"].to_s.strip
    return nil if wanted.empty?
    return nil unless File.basename(wanted) == wanted
    return nil unless FONT_EXTS.include?(File.extname(wanted).downcase)

    path = dir.join(canonical_entry_name(dir, wanted))
    path.file? ? path.to_s : nil
  rescue StandardError
    nil
  end

  def human_label(s)
    s.to_s.tr("_", " ").tr("-", " ").split.map(&:capitalize).join(" ")
  end

  def canonical_entry_name(dir, wanted_basename)
    wanted = wanted_basename.to_s
    return wanted if wanted.empty?

    Dir.children(dir).find { |entry| entry.casecmp?(wanted) } || wanted
  rescue StandardError
    wanted
  end

  def canonicalise_path_case(path)
    p = path.to_s
    d = File.dirname(p)
    b = File.basename(p)
    return p unless Dir.exist?(d)

    File.join(d, canonical_entry_name(d, b))
  rescue StandardError
    p
  end

  def choose_best_in_dir(dir)
    exts = [".woff2", ".woff", ".otf", ".ttf"]
    exts.each do |ext|
      hit = Dir.glob(dir.join("**/*#{ext}")).sort.first
      return hit if hit
    end
    nil
  end

  def wenjin_faces(root)
    dir = root.join("wenjin_mincho")
    return [] unless Dir.exist?(dir)

    p0 = choose_best(dir, "WenJinMinchoP0-Regular")
    p2 = choose_best(dir, "WenJinMinchoP2-Regular")
    p3 = choose_best(dir, "WenJinMinchoP3-Regular")
    return [] if [p0, p2, p3].compact.empty?

    faces = []
    family = "WenJin Mincho"
    label = "WenJin Mincho"

    if p0
      faces << FontFace.new(
        key: :wenjin_mincho,
        label: label,
        family: family,
        asset_path: "wenjin_mincho/#{File.basename(p0)}",
        format: css_format_for(p0),
        unicode_range: "U+0000-FFFF",
        group: nil
      )
    end

    if p2
      faces << FontFace.new(
        key: :wenjin_mincho,
        label: label,
        family: family,
        asset_path: "wenjin_mincho/#{File.basename(p2)}",
        format: css_format_for(p2),
        unicode_range: "U+20000-2A6DF, U+2A700-2B73F, U+2B740-2B81D, U+2B820-2CEAD, U+2CEB0-2EBEF",
        group: nil
      )
    end

    if p3
      faces << FontFace.new(
        key: :wenjin_mincho,
        label: label,
        family: family,
        asset_path: "wenjin_mincho/#{File.basename(p3)}",
        format: css_format_for(p3),
        unicode_range: "U+2EBF0-2EE5D, U+30000-3134A, U+31350-323AF, U+323B0-33479",
        group: nil
      )
    end

    faces
  end

  def choose_best(dir, stem)
    exts = %w[woff2 woff otf ttf]
    exts.each do |ext|
      hits = []
      hits.concat(Dir.glob(dir.join("#{stem}.#{ext}")))
      hits.concat(Dir.glob(dir.join("#{stem}.#{ext.upcase}")))
      hit = hits.sort.first
      return canonicalise_path_case(hit.to_s) if hit && File.exist?(hit)
    end
    nil
  end

  def css_format_for(path)
    ext = File.extname(path).downcase
    case ext
    when ".woff2" then "woff2"
    when ".woff" then "woff"
    when ".ttf" then "truetype"
    when ".otf" then "opentype"
    else ""
    end
  end

  def credits_path_for(key)
    @credits_paths ||= discover_credits_paths
    @credits_paths[normalise_key(key)]
  end

  def information_for(key)
    k = normalise_key(key)
    dir = font_dir_for(k)
    if dir
      readme = Dir.glob(File.join(dir, "*"))
                  .select { |p| File.file?(p) }
                  .sort
                  .find { |p| File.basename(p).downcase.start_with?("readme") }
      txt = safe_read_text(readme) if readme
      return txt if txt.present?
    end

    txt = safe_read_text(credits_path_for(k))
    txt.presence
  rescue StandardError
    nil
  end

  def credits_for(key)
    information_for(key)
  end

  def discover_credits_paths
    root = Rails.root.join("app/assets/fonts")
    out = {}
    return out unless Dir.exist?(root)

    Dir.children(root).each do |child|
      next if child.start_with?(".")
      dir = root.join(child)
      next unless Dir.exist?(dir)

      key = normalise_key(child)
      CREDIT_PATTERNS.each do |pattern|
        hit = Dir.glob(dir.join(pattern)).sort.first
        if hit
          out[key] = hit.to_s
          break
        end
      end
    end

    out
  end

  def font_dir_for(normalised_key)
    root = Rails.root.join("app/assets/fonts")
    return nil unless Dir.exist?(root)

    Dir.children(root).each do |child|
      next if child.start_with?(".")
      dir = root.join(child)
      next unless Dir.exist?(dir)
      return dir.to_s if normalise_key(child) == normalised_key
    end
    nil
  end

  def safe_read_text(path)
    return nil if path.blank?
    return nil unless File.file?(path)

    File.open(path, "rb") { |io| io.read(64 * 1024) }
        &.force_encoding("UTF-8")
        &.scrub
  rescue StandardError
    nil
  end
end
