# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"
require "yaml"
require "unicode_normalize/normalize"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module DictionaryImportSupport
  module_function

  CATEGORY_ROOT = Pathname("四庫全書/clean/經部/小學類").freeze
  DEFAULT_CONFIG = Pathname("config/dictionary_import/sources.yml").freeze
  RETRYABLE_ERRORS = [Errno::EIO, Errno::EACCES, Errno::EBUSY, Errno::ENOENT].freeze

  def timestamp
    Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
  end

  def load_config(path)
    raw = File.binread(path).force_encoding(Encoding::UTF_8)
    raise "Config is not valid UTF-8: #{path}" unless raw.valid_encoding?

    payload = YAML.safe_load(raw, permitted_classes: [], aliases: true)
    raise "Config must be a mapping: #{path}" unless payload.is_a?(Hash)

    stringify_keys(payload)
  end

  def stringify_keys(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify_keys(item) }
    when Array
      value.map { |item| stringify_keys(item) }
    else
      value
    end
  end

  def configured_works(config, profile: "all")
    all = []
    config.fetch("categories").each do |category, rows|
      Array(rows).each do |row|
        all << {
          "category" => category.to_s,
          "title" => row.fetch("title").to_s,
          "aliases" => Array(row["aliases"]).map(&:to_s).uniq
        }
      end
    end

    return all if profile == "all"

    allowed = case profile
              when "starter"
                Array(config.fetch("starter_full_works")).map(&:to_s)
              else
                raise "Unknown profile #{profile.inspect}; use all or starter"
              end
    all.select { |row| allowed.include?(row.fetch("title")) }
  end

  def work_settings(config, title)
    settings = config.fetch("work_settings", {})
    stringify_keys(settings.fetch(title.to_s, { "parser" => "probe_only", "status" => "catalogued" }))
  end

  def canonical_name(value)
    text = value.to_s.dup.force_encoding(Encoding::UTF_8)
    return value.to_s unless text.valid_encoding?

    text.unicode_normalize(:nfkc).tr("别韵増", "別韻增")
  end

  def find_work_directories(corpus_root:, category:, aliases:)
    category_dir = Pathname(corpus_root).join(CATEGORY_ROOT, category)
    return [] unless category_dir.directory?

    alias_names = Array(aliases).map { |value| canonical_name(value) }.uniq
    retry_fs("list #{category_dir}") do
      Dir.children(category_dir.to_s, encoding: Encoding::UTF_8).map do |name|
        category_dir.join(name)
      end.select(&:directory?).select do |child|
        alias_names.include?(canonical_name(child.basename.to_s))
      end.sort_by { |path| path.basename.to_s }
    end
  end

  def read_json(path)
    raw = retry_fs("read #{path}") { File.binread(path) }.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8 JSON: #{path}" unless raw.valid_encoding?

    payload = JSON.parse(raw)
    raise "JSON root must be a mapping: #{path}" unless payload.is_a?(Hash)

    stringify_keys(payload)
  end

  def metadata_documents(metadata)
    direct = Array(metadata["documents"])
    edition_docs = Array(metadata["editions"]).flat_map { |edition| Array(edition["documents"]) }
    translation_docs = Array(metadata["translations"]).flat_map do |group|
      Array(group["documents"])
    end
    (direct + edition_docs + translation_docs).map { |row| stringify_keys(row) }
  end

  def resolve_document_path(corpus_root:, work_dir:, document:)
    declared = document["path"].to_s.tr("\\", "/")
    candidates = []
    candidates << Pathname(corpus_root).join(declared) unless declared.empty?
    candidates << Pathname(work_dir).join(document["file"].to_s) unless document["file"].to_s.empty?
    candidates.find(&:file?)
  end

  def safe_read_text(path)
    raw = retry_fs("read #{path}") { File.binread(path) }
    text = raw.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8 text: #{path}" unless text.valid_encoding?

    text
  end

  def sha256(path)
    retry_fs("hash #{path}") { Digest::SHA256.file(path).hexdigest }
  end

  def retry_fs(label, attempts: 5)
    attempt = 0
    begin
      attempt += 1
      return yield
    rescue *RETRYABLE_ERRORS => error
      raise if attempt >= attempts

      delay = 0.15 * (2**(attempt - 1))
      warn "[retry] #{label}: #{error.class}: #{error.message}; retry #{attempt}/#{attempts} in #{format('%.2f', delay)}s"
      sleep(delay)
      retry
    end
  end

  def write_json(path, payload)
    atomic_write(path, JSON.pretty_generate(payload) + "\n")
  end

  def write_jsonl(path, rows)
    FileUtils.mkdir_p(Pathname(path).dirname)
    temp = "#{path}.tmp-#{Process.pid}"
    File.open(temp, "wb") do |io|
      rows.each { |row| io.write(JSON.generate(row) + "\n") }
    end
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(Pathname(path).dirname)
    temp = "#{path}.tmp-#{Process.pid}"
    CSV.open(temp, "wb", write_headers: true, headers: headers, force_quotes: true) do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp
  end

  def atomic_write(path, content)
    path = Pathname(path)
    FileUtils.mkdir_p(path.dirname)
    temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
    File.open(temp, "wb") { |io| io.write(content) }
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp
  end

  def relative(path, root)
    Pathname(path).relative_path_from(Pathname(root)).to_s.tr("\\", "/")
  rescue ArgumentError
    Pathname(path).to_s.tr("\\", "/")
  end

  def parse_chinese_number(token)
    s = token.to_s.strip
    return s.to_i if s.match?(/\A\d+\z/)

    digits = { "〇" => 0, "零" => 0, "一" => 1, "二" => 2, "三" => 3, "四" => 4,
               "五" => 5, "六" => 6, "七" => 7, "八" => 8, "九" => 9 }
    return digits[s] if digits.key?(s)

    if s.include?("十")
      left, right = s.split("十", 2)
      tens = left.to_s.empty? ? 1 : digits[left]
      ones = right.to_s.empty? ? 0 : digits[right]
      return (tens * 10) + ones if tens && ones
    end

    nil
  end
end
