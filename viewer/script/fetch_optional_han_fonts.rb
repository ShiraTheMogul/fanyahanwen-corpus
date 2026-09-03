# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FONT_ROOT = File.join(ROOT, "app", "assets", "fonts")
BOM = "\xEF\xBB\xBF".b

Source = Struct.new(:url, :verify, :digest, keyword_init: true)

SOURCES = {
  pengli: Source.new(
    url: "https://github.com/lxgw/Pengli/releases/download/v1.033/PengliWenKai-Regular.ttf",
    verify: :sha256,
    digest: "4ef70f5ba372d2da3a6767302cca516768f8c75c5c0a9b3e455216f3a8156edc"
  ),
  lxgw_light: Source.new(
    url: "https://raw.githubusercontent.com/lxgw/LxgwWenkaiKR/0073253b91ccf8a85f81084eb244fba48f0c67ec/fonts/TTF/LXGWWenKaiKR-Light.ttf",
    verify: :git_blob,
    digest: "269c7c7d7ca6542657d726777fbd797f5d681268"
  ),
  lxgw_regular: Source.new(
    url: "https://raw.githubusercontent.com/lxgw/LxgwWenkaiKR/0073253b91ccf8a85f81084eb244fba48f0c67ec/fonts/TTF/LXGWWenKaiKR-Regular.ttf",
    verify: :git_blob,
    digest: "e7f65c80af79db33b84a25447ba4557789366c1c"
  ),
  lxgw_medium: Source.new(
    url: "https://raw.githubusercontent.com/lxgw/LxgwWenkaiKR/0073253b91ccf8a85f81084eb244fba48f0c67ec/fonts/TTF/LXGWWenKaiKR-Medium.ttf",
    verify: :git_blob,
    digest: "cc25834d11ab1abf6eeed233a4a8a2ae64ce6b92"
  ),
  pretendard_jp: Source.new(
    url: "https://raw.githubusercontent.com/orioncactus/pretendard/v1.3.9/packages/pretendard-jp/dist/public/static/PretendardJP-Regular.otf",
    verify: :git_blob,
    digest: "dc5340c8fa46a92480e4f84265ddfdd592d98c8e"
  ),
  shanggu_archive: Source.new(
    url: "https://github.com/GuiWonder/Shanggu/releases/download/1.028/ShangguSerifTTFs.7z",
    verify: :sha256,
    digest: "31b28af234cbbcada71cd11f6c7a6c84a7a9698ab95692c797b8b51e70c6758b"
  )
}.freeze

LICENSES = {
  pengli: Source.new(
    url: "https://raw.githubusercontent.com/lxgw/Pengli/v1.033/OFL.txt",
    verify: :git_blob,
    digest: "ef23865afc549a9c6fa5660d68b86c66dc3e373f"
  ),
  lxgw: Source.new(
    url: "https://raw.githubusercontent.com/lxgw/LxgwWenkaiKR/0073253b91ccf8a85f81084eb244fba48f0c67ec/OFL.txt",
    verify: :git_blob,
    digest: "9b63d8f6218d1eb4a222c7e357f977e20c42d10d"
  ),
  pretendard: Source.new(
    url: "https://raw.githubusercontent.com/orioncactus/pretendard/v1.3.9/LICENSE",
    verify: :git_blob,
    digest: "c0592ca0072da4537bdc064eb935d88e9bb4361d"
  ),
  shanggu: Source.new(
    url: "https://raw.githubusercontent.com/GuiWonder/Shanggu/1.028/LICENSE.txt",
    verify: :git_blob,
    digest: "77b17316cf1e8ab216bd6743996dfc67cc86216a"
  )
}.freeze

def git_blob_sha1(bytes)
  Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)
end

def download(source)
  bytes = URI.open(source.url, "rb", redirect: true, &:read)
  actual = source.verify == :sha256 ? Digest::SHA256.hexdigest(bytes) : git_blob_sha1(bytes)
  raise "Verification failed for #{source.url}: expected #{source.digest}, got #{actual}" unless actual == source.digest
  bytes
end

def write_font(key:, label:, family:, group:, filename:, bytes:, license_bytes:, source_note:)
  dir = File.join(FONT_ROOT, key)
  FileUtils.mkdir_p(dir)
  File.binwrite(File.join(dir, filename), bytes)
  File.binwrite(File.join(dir, "OFL.txt"), license_bytes)

  metadata = {
    "label" => label,
    "family" => family,
    "group" => group,
    "file" => filename
  }
  File.binwrite(File.join(dir, "font.json"), JSON.pretty_generate(metadata) + "\n")
  File.binwrite(File.join(dir, "README.txt"), source_note + "\n")
  puts "installed #{key}/#{filename}"
end

FileUtils.mkdir_p(FONT_ROOT)

pengli_license = download(LICENSES.fetch(:pengli))
write_font(
  key: "pengli_wenkai",
  label: "Pengli WenKai",
  family: "Fanya Pengli WenKai",
  group: nil,
  filename: "PengliWenKai-Regular.ttf",
  bytes: download(SOURCES.fetch(:pengli)),
  license_bytes: pengli_license,
  source_note: "Pengli WenKai v1.033 by LXGW. Source: https://github.com/lxgw/Pengli . SIL Open Font License 1.1."
)

lxgw_license = download(LICENSES.fetch(:lxgw))
[
  ["lxgw_wenkai_kr_light", "LXGW WenKai KR - Light", "Fanya LXGW WenKai KR Light", "LXGWWenKaiKR-Light.ttf", :lxgw_light],
  ["lxgw_wenkai_kr_regular", "LXGW WenKai KR - Regular", "Fanya LXGW WenKai KR Regular", "LXGWWenKaiKR-Regular.ttf", :lxgw_regular],
  ["lxgw_wenkai_kr_medium", "LXGW WenKai KR - Medium", "Fanya LXGW WenKai KR Medium", "LXGWWenKaiKR-Medium.ttf", :lxgw_medium]
].each do |key, label, family, filename, source_key|
  write_font(
    key: key,
    label: label,
    family: family,
    group: "LXGW WenKai KR",
    filename: filename,
    bytes: download(SOURCES.fetch(source_key)),
    license_bytes: lxgw_license,
    source_note: "LXGW WenKai KR at commit 0073253b91ccf8a85f81084eb244fba48f0c67ec by LXGW. Source: https://github.com/lxgw/LxgwWenkaiKR . SIL Open Font License 1.1."
  )
end

pretendard_license = download(LICENSES.fetch(:pretendard))
write_font(
  key: "pretendard_jp",
  label: "Pretendard JP",
  family: "Fanya Pretendard JP",
  group: nil,
  filename: "PretendardJP-Regular.otf",
  bytes: download(SOURCES.fetch(:pretendard_jp)),
  license_bytes: pretendard_license,
  source_note: "Pretendard JP v1.3.9 by Kil Hyung-jin and contributors. Source: https://github.com/orioncactus/pretendard . SIL Open Font License 1.1. Upstream documents ss05 for Korea-localized glyphs; this font choice does not force that feature."
)

# Shanggu's release font is distributed as a 7z archive. We install the
# non-ST Serif Regular variants only; ST performs font-level Simplified-to-
# Traditional substitution and is deliberately excluded because Fanya keeps
# text conversion in CharacterStandards.
seven_zip = %w[7zz 7z].find { |command| system("command -v #{command} >/dev/null 2>&1") }
if seven_zip
  shanggu_license = download(LICENSES.fetch(:shanggu))
  Dir.mktmpdir("fanya-shanggu") do |tmp|
    archive = File.join(tmp, "ShangguSerifTTFs.7z")
    File.binwrite(archive, download(SOURCES.fetch(:shanggu_archive)))
    listing, status = Open3.capture2(seven_zip, "l", "-slt", archive)
    raise "Could not list Shanggu archive" unless status.success?

    paths = listing.scan(/^Path = (.+)$/).flatten.select do |path|
      File.basename(path).match?(/\AShangguSerif(?:TC|SC|JP)?-Regular\.ttf\z/)
    end
    raise "No expected Shanggu Serif Regular fonts found in verified archive" if paths.empty?

    paths.each do |archive_path|
      _out, extract_status = Open3.capture2e(seven_zip, "e", "-y", "-o#{tmp}", archive, archive_path)
      raise "Could not extract #{archive_path}" unless extract_status.success?

      filename = File.basename(archive_path)
      suffix = filename[/\AShangguSerif(TC|SC|JP)?-Regular\.ttf\z/, 1].to_s
      key_suffix = suffix.empty? ? "" : "_#{suffix.downcase}"
      label_suffix = suffix.empty? ? "" : " #{suffix}"
      write_font(
        key: "shanggu_serif#{key_suffix}",
        label: "Shanggu Serif#{label_suffix}",
        family: "Fanya Shanggu Serif#{label_suffix}",
        group: "Shanggu Serif",
        filename: filename,
        bytes: File.binread(File.join(tmp, filename)),
        license_bytes: shanggu_license,
        source_note: "Shanggu Serif 1.028 by GuiWonder. Source: https://github.com/GuiWonder/Shanggu . SIL Open Font License 1.1. The ST conversion-font variant is intentionally not installed."
      )
    end
  end
else
  warn "Shanggu Serif skipped: install 7zz or 7z, then run this script again. Other fonts were installed."
end

puts "Optional Han fonts installed. Restart Rails so HanFonts refreshes its production cache."
