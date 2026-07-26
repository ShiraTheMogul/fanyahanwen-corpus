# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"
require "set"
require "shellwords"
require "time"
require "yaml"
require "zlib"
require "unicode_normalize/normalize"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module DictionaryImport
  module Support
    module_function

    DEFAULT_CONFIG = Pathname("config/dictionary_import/sources.yml").freeze
    RETRYABLE_ERRORS = [Errno::EIO, Errno::EACCES, Errno::EBUSY, Errno::ENOENT].freeze
    ROLE_DIRS = %w[raw variants variant reconstruction reconstructions translation translations annotation annotations kanbun hanmun hanvan].to_set.freeze

    def timestamp
      Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def read_utf8(path)
      raw = retry_fs("read #{path}") { File.binread(path) }
      text = raw.force_encoding(Encoding::UTF_8)
      raise "Invalid UTF-8: #{path}" unless text.valid_encoding?
      text
    end

    def read_json(path)
      value = JSON.parse(read_utf8(path))
      raise "JSON root is not an object: #{path}" unless value.is_a?(Hash)
      stringify_keys(value)
    end

    def load_config(path)
      value = YAML.safe_load(read_utf8(path), permitted_classes: [], aliases: true)
      raise "Configuration root is not an object: #{path}" unless value.is_a?(Hash)
      stringify_keys(value)
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
      rows = config.fetch("categories").flat_map do |category, works|
        Array(works).map do |work|
          {
            "category" => category.to_s,
            "title" => work.fetch("title").to_s,
            "aliases" => ([work.fetch("title").to_s] + Array(work["aliases"]).map(&:to_s)).uniq
          }
        end
      end
      return rows if profile == "all"

      wanted = if profile == "starter"
                 Array(config.fetch("starter_full_works")).map(&:to_s)
               else
                 profiles = stringify_keys(config.fetch("profiles", {}))
                 raise "Unknown profile #{profile.inspect}" unless profiles.key?(profile.to_s)

                 Array(profiles.fetch(profile.to_s)).map(&:to_s)
               end
      rows.select { |row| wanted.include?(row.fetch("title")) }
    end

    def work_settings(config, title)
      stringify_keys(config.fetch("work_settings", {}).fetch(title.to_s, {
        "parser" => "probe_only",
        "status" => "catalogued"
      }))
    end

    # Matching only. This deliberately does not rewrite source text.
    def title_key(value)
      value.to_s
        .unicode_normalize(:nfkc)
        .tr("别韵増叶彚㣲", "別韻增葉彙微")
        .gsub(/[\s_\-‐‑–—・·]/, "")
        .gsub(/[()（）\[\]【】《》〈〉]/, "")
        .sub(/四庫全書本\z/, "")
        .sub(%r{/卷[〇零一二三四五六七八九十百0-9]+\z}, "")
    end

    def portable_component(value)
      value.to_s.each_char.map do |char|
        codepoint = char.ord
        if codepoint.between?(0x20, 0x7e) && char.match?(/[A-Za-z0-9._()\-]/)
          char
        else
          format("#U%x", codepoint)
        end
      end.join
    end

    def portable_work_dir(work_id, title)
      id = work_id.to_s.empty? ? "no-id" : work_id.to_s
      "#{id}--#{portable_component(title)}"
    end

    def relative(path, root)
      Pathname(path).relative_path_from(Pathname(root)).to_s.tr("\\", "/")
    rescue ArgumentError
      Pathname(path).to_s.tr("\\", "/")
    end

    def retry_fs(label, attempts: 6)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue *RETRYABLE_ERRORS => error
        raise if attempt >= attempts
        delay = 0.15 * (2**(attempt - 1))
        warn "[retry] #{label}: #{error.class}: #{error.message}; #{attempt}/#{attempts} in #{format('%.2f', delay)}s"
        sleep(delay)
        retry
      end
    end

    def sha256(path)
      retry_fs("hash #{path}") { Digest::SHA256.file(path).hexdigest }
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

    def write_json(path, payload)
      atomic_write(path, JSON.pretty_generate(payload) + "\n")
    end

    def write_jsonl(path, rows)
      path = Pathname(path)
      FileUtils.mkdir_p(path.dirname)
      temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
      File.open(temp, "wb") do |io|
        rows.each { |row| io.write(JSON.generate(row) + "\n") }
      end
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if defined?(temp) && temp
    end

    def write_csv(path, headers, rows)
      path = Pathname(path)
      FileUtils.mkdir_p(path.dirname)
      temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
      CSV.open(temp, "wb", write_headers: true, headers: headers, force_quotes: true) do |csv|
        rows.each { |row| csv << headers.map { |header| row[header] } }
      end
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if defined?(temp) && temp
    end

    def metadata_documents(metadata)
      rows = []
      Array(metadata["documents"]).each { |doc| rows << ["documents", nil, doc] }
      Array(metadata["editions"]).each do |edition|
        Array(edition["documents"]).each { |doc| rows << ["editions", edition, doc] }
      end
      Array(metadata["translations"]).each do |group|
        Array(group["documents"]).each { |doc| rows << ["translations", group, doc] }
      end
      rows.map do |container, parent, document|
        [container, stringify_keys(parent || {}), stringify_keys(document)]
      end
    end

    def resolve_document_path(corpus_root:, work_dir:, document:)
      candidates = []
      declared = document["path"].to_s.tr("\\", "/")
      candidates << Pathname(corpus_root).join(declared) unless declared.empty?
      candidates << Pathname(work_dir).join(document["file"].to_s) unless document["file"].to_s.empty?
      candidates.find(&:file?)
    end

    def clean_metadata_paths(corpus_root)
      root = Pathname(corpus_root)
      paths = []
      roots = Dir.children(root.to_s, encoding: Encoding::UTF_8).filter_map do |name|
        path = root.join(name, "clean")
        path if path.directory?
      end

      roots.each_with_index do |clean_root, root_index|
        puts "  [index #{root_index + 1}/#{roots.length}] #{clean_root}"
        Find.find(clean_root.to_s) do |name|
          path = Pathname(name)
          if path.directory? && ROLE_DIRS.include?(path.basename.to_s.downcase)
            Find.prune
            next
          end
          paths << path if path.file? && path.basename.to_s == "metadata.json"
          puts "    metadata found=#{paths.length}" if (paths.length % 25_000).zero? && paths.any?
        rescue *RETRYABLE_ERRORS => error
          warn "[index] skipped #{path}: #{error.class}: #{error.message}"
        end
      end
      paths
    end

    def parse_chinese_number(token)
      text = token.to_s.strip
      return text.to_i if text.match?(/\A\d+\z/)
      digits = { "〇" => 0, "零" => 0, "一" => 1, "二" => 2, "三" => 3, "四" => 4,
                 "五" => 5, "六" => 6, "七" => 7, "八" => 8, "九" => 9 }
      return digits[text] if digits.key?(text)
      return 10 if text == "十"
      if text.include?("十")
        left, right = text.split("十", 2)
        tens = left.to_s.empty? ? 1 : digits[left]
        ones = right.to_s.empty? ? 0 : digits[right]
        return (tens * 10) + ones if tens && ones
      end
      nil
    end

    def git_context(root)
      root = Pathname(root)
      return {} unless root.join(".git").exist?
      head = `git -C #{Shellwords.escape(root.to_s)} rev-parse HEAD 2>/dev/null`.strip
      status = `git -C #{Shellwords.escape(root.to_s)} status --short 2>/dev/null`
      { "head" => head, "status_short" => status }
    rescue StandardError
      {}
    end
  end
end
