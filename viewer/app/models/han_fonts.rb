# frozen_string_literal: true

# Discover available Han-script fonts from app/assets/fonts and expose them
# to the UI (rightbar) and to a dynamic @font-face injector in the layout.
#
# Design goals:
# - Drop a font folder into app/assets/fonts/<font_name>/ and it shows up automatically.
# - Keep the "choice" stored in the session as a simple symbol.
# - Avoid breaking the existing layout: we only set font-family on main content
#   (and tooltips) based on a scope toggle.
# - Do NOT let Han fonts override Latin/ASCII: we enforce unicode-range = Han blocks.
#
# Folder convention (recommended):
#   app/assets/fonts/<font_key>/
#     <font file>.woff2 / .woff / .otf / .ttf
#     LICENSE* / OFL* / CREDITS* / README* (optional)
#
# We still support "loose" font files directly under app/assets/fonts for backwards
# compatibility, but folders are nicer (and make credits easy).
module HanFonts
  FONT_EXTS = %w[.woff2 .woff .otf .ttf].freeze
  CREDIT_PATTERNS = [
    "LICENSE*",
    "OFL*",
    "CREDITS*",
    "README*",
    "COPYING*"
  ].freeze

  # A single font face (file) entry.
  FontFace = Struct.new(
    :key,          # symbol stored in session
    :label,        # UI label
    :family,       # CSS font-family name
    :asset_path,   # path relative to app/assets/fonts
    :format,       # css format() value
    :unicode_range,# unicode-range string
    keyword_init: true
  )

  module_function

  def choices
    faces.group_by(&:key).map do |_key, group|
      [group.first.label, group.first.key]
    end.sort_by { |label, _| label.downcase }
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

  # A CSS-ready font stack string.
  # We always include WenJin Mincho as the preferred fallback for missing glyphs.
  def stack_for(key)
    fam = family_for(key)
    wen = family_for(:wenjin_mincho) || "serif"

    if fam.to_s == wen.to_s
      %Q{"#{wen}", serif}
    else
      %Q{"#{fam}", "#{wen}", serif}
    end
  end

  # Allowed scopes for applying the selected Han font.
  # - :all       applies to all Han text in main content + tooltip
  # - :headwords applies only to headwords (dictionary + tooltip)
  def allowed_scopes
    %i[all headwords]
  end

  def default_scope
    :all
  end

def faces
    return discover_faces if defined?(Rails) && Rails.env.development?
    @faces ||= discover_faces
  end

  def refresh!
    @faces = discover_faces
    @credits_paths = nil
  end

  # ---- internal ----

  def normalise_key(value)
    value.to_s.strip.downcase.tr(" ", "_").tr("-", "_").to_sym
  end

  def discover_faces
    root = Rails.root.join("app/assets/fonts")
    return [] unless Dir.exist?(root)

    out = []

    # Special handling for WenJin Mincho: split across planes.
    out.concat(wenjin_faces(root))

    # 1) Folder-based fonts (recommended)
    Dir.children(root).each do |child|
      next if child.start_with?(".")
      dir = root.join(child)
      next unless Dir.exist?(dir)
      next if child == "wenjin_mincho"

      best = choose_best_in_dir(dir)
      next unless best

      rel = Pathname(best).relative_path_from(root).to_s
      key = normalise_key(child)
      label = human_label(child)

      out << FontFace.new(
        key: key,
        label: label,
        family: label,
        asset_path: rel,
        format: css_format_for(rel),
        unicode_range: UnicodeRanges.han_css_unicode_range
      )
    end

    # 2) Legacy loose files directly under fonts/
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
        unicode_range: UnicodeRanges.han_css_unicode_range
      )
    end

    out
  end

  def human_label(s)
    s.to_s.tr("_", " ").tr("-", " ").split.map(&:capitalize).join(" ")
  end


# On case-insensitive filesystems (e.g. WSL on /mnt/c), Dir.glob can match a file
# but return a path whose *extension case* doesn't match the real on-disk filename.
# Propshaft indexes assets by their real logical path, so a mismatch like
#   WenJinMinchoP0-Regular.WOFF2  vs  WenJinMinchoP0-Regular.woff2
# will crash the page.
#
# This helper re-resolves a basename to the actual entry name in that directory
# (case-insensitive match, but returns the real case).
def canonical_entry_name(dir, wanted_basename)
  wanted = wanted_basename.to_s
  return wanted if wanted.empty?

  Dir.children(dir).find { |e| e.casecmp?(wanted) } || wanted
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
    # Prefer woff2 > woff > otf > ttf
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
        unicode_range: "U+0000-FFFF"
      )
    end

    if p2
      faces << FontFace.new(
        key: :wenjin_mincho,
        label: label,
        family: family,
        asset_path: "wenjin_mincho/#{File.basename(p2)}",
        format: css_format_for(p2),
        unicode_range: "U+20000-2A6DF, U+2A700-2B73F, U+2B740-2B81D, U+2B820-2CEAD, U+2CEB0-2EBEF"
      )
    end

    if p3
      faces << FontFace.new(
        key: :wenjin_mincho,
        label: label,
        family: family,
        asset_path: "wenjin_mincho/#{File.basename(p3)}",
        format: css_format_for(p3),
        unicode_range: "U+2EBF0-2EE5D, U+31350-323AF, U+323B0-33479"
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

  # Returns human-readable information about a font, if present.
  #
  # Convention:
  # - Prefer any file inside the font folder whose basename begins with "readme"
  #   (case-insensitive). This tends to be where authors put credits + notes.
  # - Fall back to LICENSE/OFL/CREDITS/COPYING style files if no README exists.
  #
  # If nothing is found, returns nil.
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

    # fall back to earlier credit-file discovery
    txt = safe_read_text(credits_path_for(k))
    txt.presence
  rescue StandardError
    nil
  end

  # Backwards-compat shim (older views called this).
  def credits_for(key)
    information_for(key)
  end

  def discover_credits_paths
    root = Rails.root.join("app/assets/fonts")
    out = {}
    return out unless Dir.exist?(root)

    # folder fonts
    Dir.children(root).each do |child|
      next if child.start_with?(".")
      dir = root.join(child)
      next unless Dir.exist?(dir)

      key = normalise_key(child)
      CREDIT_PATTERNS.each do |pat|
        hit = Dir.glob(dir.join(pat)).sort.first
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

    # Avoid accidentally slurping huge files.
    File.open(path, "rb") { |io| io.read(64 * 1024) }
      &.force_encoding("UTF-8")
      &.scrub
  rescue StandardError
    nil
  end
end
