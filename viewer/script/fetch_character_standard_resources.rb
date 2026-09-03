# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"

ROOT = File.expand_path("..", __dir__)
CONFIG = File.join(ROOT, "config")
UPSTREAM_COMMIT = "33ba491670d5aff20bfbc41d5f412ac8607ba722"
BOM = "\xEF\xBB\xBF".b

Resource = Struct.new(:url, :blob_sha1, :destination, :bom, keyword_init: true)

BASE = "https://raw.githubusercontent.com/TerryTian-tech/OpenCC-Traditional-Chinese-characters-according-to-Chinese-government-standards/#{UPSTREAM_COMMIT}"

RESOURCES = [
  Resource.new(
    url: "#{BASE}/t2gov/TGCharacters.txt",
    blob_sha1: "6a1bc93352edb9d6308d7607a4a16f3899bcf47c",
    destination: File.join(CONFIG, "mainland_traditional_characters.txt"),
    bom: true
  ),
  Resource.new(
    url: "#{BASE}/t2gov/TGPhrases.txt",
    blob_sha1: "0e04f68619faad471309a2c65807ba8f5bef9188",
    destination: File.join(CONFIG, "mainland_traditional_phrases.txt"),
    bom: true
  ),
  Resource.new(
    url: "#{BASE}/t2gov/CJK_Compatibility_Ideographs.txt",
    blob_sha1: "91304af8def6d96b0d00dd482c8a934dedcebfa6",
    destination: File.join(CONFIG, "mainland_traditional_cjk_compatibility.txt"),
    bom: true
  ),
  Resource.new(
    url: "#{BASE}/LICENSE",
    blob_sha1: "261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64",
    destination: File.join(CONFIG, "mainland_traditional_OPENCC_LICENSE.txt"),
    bom: false
  )
].freeze

def git_blob_sha1(bytes)
  Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)
end

def download(url)
  URI.open(url, "rb", redirect: true, &:read)
end

def write_verified(resource)
  bytes = download(resource.url)
  actual = git_blob_sha1(bytes)
  unless actual == resource.blob_sha1
    raise "Source verification failed for #{resource.url}: expected Git blob #{resource.blob_sha1}, got #{actual}"
  end

  FileUtils.mkdir_p(File.dirname(resource.destination))
  payload = resource.bom ? BOM + bytes.sub(/\A\xEF\xBB\xBF/n, "".b) : bytes
  File.binwrite(resource.destination, payload)
  puts "installed #{resource.destination.sub(ROOT + File::SEPARATOR, "")}"
end

RESOURCES.each { |resource| write_verified(resource) }

# This config mirrors upstream t2gov.json, using Fanya-prefixed filenames so
# the downloaded dictionaries cannot collide with unrelated OpenCC resources.
opencc_config = {
  "name" => "Traditional Chinese to Mainland Traditional (PRC standard)",
  "normalization" => [
    { "dict" => { "type" => "text", "file" => "mainland_traditional_cjk_compatibility.txt" } }
  ],
  "conversion_chain" => [
    {
      "dict" => {
        "type" => "group",
        "match_policy" => "short_circuit",
        "dicts" => [
          { "type" => "text", "file" => "mainland_traditional_phrases.txt" },
          { "type" => "text", "file" => "mainland_traditional_characters.txt" }
        ]
      }
    }
  ]
}
config_path = File.join(CONFIG, "mainland_traditional_opencc.json")
File.binwrite(config_path, JSON.pretty_generate(opencc_config) + "\n")
puts "installed #{config_path.sub(ROOT + File::SEPARATOR, "")}"

paths = {
  "data_file" => File.join(CONFIG, "mainland_traditional_characters.txt"),
  "phrases_file" => File.join(CONFIG, "mainland_traditional_phrases.txt"),
  "compatibility_file" => File.join(CONFIG, "mainland_traditional_cjk_compatibility.txt"),
  "config_file" => config_path,
  "license_file" => File.join(CONFIG, "mainland_traditional_OPENCC_LICENSE.txt")
}
manifest = {
  "upstream_repository" => "TerryTian-tech/OpenCC-Traditional-Chinese-characters-according-to-Chinese-government-standards",
  "upstream_commit" => UPSTREAM_COMMIT,
  "contributors" => ["TerryTian-tech", "Yi Jianpeng", "Hu Xinmei", "Duan Yatong"],
  "reference" => "《通用规范汉字表》(2013)"
}
paths.each do |key, path|
  manifest[key] = File.basename(path)
  manifest["#{key.delete_suffix('_file')}_sha256"] = Digest::SHA256.file(path).hexdigest
end
manifest_path = File.join(CONFIG, "mainland_traditional_manifest.json")
manifest_bytes = JSON.pretty_generate(manifest).encode("UTF-8") + "\n"
File.binwrite(manifest_path, BOM + manifest_bytes.b)
puts "installed #{manifest_path.sub(ROOT + File::SEPARATOR, "")}"
puts "Mainland Traditional resources installed and verified. Restart Rails if it is already running."
