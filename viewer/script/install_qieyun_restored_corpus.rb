#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require_relative "build_qieyun_restored_corpus"

module QieyunRestoredInstall
  class Error < StandardError; end

  TARGET_RELATIVE_PATH = "中國漢文/clean/隋朝/隋/切韻"
  KNOWN_SOURCE_REVISION = "6db59f89004ac747f5e6aa2d54e54bf6f6af2926"

  EDITION_ROWS = [
    {
      key: :fujita,
      edition_label: "藤田拓海復元本",
      directory_name: "藤田拓海",
      file: "切韻（藤田拓海復元本）.txt"
    },
    {
      key: :li,
      edition_label: "李永富復元本",
      directory_name: "李永富",
      file: "切韻（李永富復元本）.txt"
    }
  ].freeze

  class Registry
    REQUIRED_HEADERS = %w[kind id identity_key path title parent_work_id source_document_id status].freeze

    attr_reader :path, :headers, :rows, :new_rows

    def initialize(path)
      @path = Pathname(path).expand_path
      raise Error, "ID registry not found: #{@path}" unless @path.file?

      table = CSV.read(@path, headers: true, encoding: "bom|utf-8")
      @headers = table.headers.compact.map(&:to_s)
      missing = REQUIRED_HEADERS - @headers
      raise Error, "ID registry is missing columns: #{missing.join(', ')}" if missing.any?

      @rows = table.map(&:to_h)
      @new_rows = []
      @by_key = {}
      @used_ids = Hash.new { |hash, key| hash[key] = {} }

      @rows.each_with_index do |row, index|
        kind = row["kind"].to_s
        identity_key = row["identity_key"].to_s
        id = positive_integer(row["id"])
        next if kind.empty? || identity_key.empty? || id.nil?

        key = [kind, identity_key]
        raise Error, "Duplicate registry identity #{key.inspect}" if @by_key.key?(key)
        if @used_ids[kind].key?(id)
          raise Error, "Duplicate #{kind} ID #{id} in registry rows #{@used_ids[kind][id]} and #{index + 2}"
        end

        @by_key[key] = row
        @used_ids[kind][id] = index + 2
      end
    end

    def reserve(kind:, identity_key:, path:, title:, parent_work_id: nil, source_document_id: nil)
      kind = kind.to_s
      identity_key = identity_key.to_s
      existing = @by_key[[kind, identity_key]]
      return positive_integer(existing.fetch("id")) if existing

      id = next_id(kind)
      row = headers.to_h { |header| [header, nil] }
      row.merge!(
        "kind" => kind,
        "id" => id,
        "identity_key" => identity_key,
        "path" => path.to_s,
        "title" => title.to_s,
        "parent_work_id" => parent_work_id,
        "source_document_id" => source_document_id,
        "status" => "active"
      )
      rows << row
      new_rows << row
      @by_key[[kind, identity_key]] = row
      @used_ids[kind][id] = rows.length + 1
      id
    end

    def write(output_path)
      output_path = Pathname(output_path)
      FileUtils.mkdir_p(output_path.dirname)
      CSV.open(output_path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
        rows.each { |row| csv << headers.map { |header| row[header] } }
      end
      output_path
    end

    def write_delta(output_path)
      output_path = Pathname(output_path)
      FileUtils.mkdir_p(output_path.dirname)
      CSV.open(output_path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
        new_rows.each { |row| csv << headers.map { |header| row[header] } }
      end
      output_path
    end

    private

    def next_id(kind)
      (@used_ids[kind].keys.max || 0) + 1
    end

    def positive_integer(value)
      number = Integer(value)
      number.positive? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end
  end

  class Installer
    attr_reader :source_dir, :corpus_root, :id_registry_path, :output_root,
                :source_revision, :apply, :replace_existing

    def initialize(source_dir:, corpus_root:, id_registry_path: nil, output_root: nil,
                   source_revision: nil, apply: false, replace_existing: false)
      @source_dir = Pathname(source_dir).expand_path
      @corpus_root = Pathname(corpus_root).expand_path
      @id_registry_path = id_registry_path ? Pathname(id_registry_path).expand_path : discover_registry
      @output_root = Pathname(output_root || default_output_root).expand_path
      @source_revision = source_revision.to_s.strip
      @apply = !!apply
      @replace_existing = !!replace_existing
    end

    def run
      validate_inputs!
      revision = resolved_source_revision
      registry = Registry.new(id_registry_path)
      ids = reserve_ids(registry)

      FileUtils.rm_rf(output_root)
      FileUtils.mkdir_p(output_root)

      build_root = output_root.join("qieyun_build")
      summary = QieyunRestoredCorpus::Builder.new(
        source_dir: source_dir,
        output_dir: build_root,
        target_relative_path: TARGET_RELATIVE_PATH,
        ids: ids,
        source_revision: revision
      ).build

      raise Error, "Qieyun builder did not produce an apply-ready overlay" unless summary.fetch("apply_ready")

      overlay_root = build_root.join("corpus_overlay")
      work_root = overlay_root.join(TARGET_RELATIVE_PATH)
      verify_build!(summary, work_root, ids, revision)

      updated_registry = registry.write(output_root.join("metadata_id_registry.updated.csv"))
      delta_registry = registry.write_delta(output_root.join("metadata_id_registry.qieyun_delta.csv"))
      write_plan(summary, ids, revision, overlay_root, updated_registry, delta_registry)

      apply_build!(work_root, updated_registry) if apply

      result = {
        "schema_version" => 1,
        "created_at" => Time.now.utc.iso8601,
        "apply" => apply,
        "target_relative_path" => TARGET_RELATIVE_PATH,
        "source_revision" => revision,
        "id_registry" => id_registry_path.to_s,
        "ids" => ids.transform_keys(&:to_s),
        "overlay_root" => overlay_root.to_s,
        "updated_registry" => updated_registry.to_s,
        "registry_delta" => delta_registry.to_s,
        "installed_path" => apply ? corpus_root.join(TARGET_RELATIVE_PATH).to_s : nil,
        "editions" => summary.fetch("editions")
      }
      output_root.join("install_summary.json").write(JSON.pretty_generate(result) + "\n", encoding: "UTF-8")
      puts summary_text(result)
      result
    end

    private

    def validate_inputs!
      raise Error, "Qieyun source directory not found: #{source_dir}" unless source_dir.directory?
      raise Error, "Corpus root not found: #{corpus_root}" unless corpus_root.directory?
      raise Error, "ID registry not found: #{id_registry_path}" unless id_registry_path&.file?
      raise Error, "Output directory may not be the corpus root" if output_root == corpus_root

      target = corpus_root.join(TARGET_RELATIVE_PATH)
      if apply && target.exist? && !replace_existing
        raise Error, "Target already exists: #{target}. Re-run with --replace-existing only after reviewing it."
      end
    end

    def discover_registry
      candidates = Dir.glob(Pathname.pwd.join("tmp/corpus_metadata_json/full_*/metadata_id_registry.csv").to_s)
      candidates.concat(Dir.glob(Pathname.pwd.join("tmp/**/metadata_id_registry.csv").to_s))
      candidates.map { |path| Pathname(path) }.select(&:file?).uniq.max_by(&:mtime)
    end

    def default_output_root
      Pathname.pwd.join("tmp/qieyun_install", "plan_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
    end

    def resolved_source_revision
      return source_revision unless source_revision.empty?

      detected = detect_git_revision
      return detected unless detected.empty?

      raise Error,
        "The source directory is not a Git checkout. Pass --source-revision #{KNOWN_SOURCE_REVISION} for the reviewed qieyun.zip source."
    end

    def detect_git_revision
      return "" unless source_dir.join(".git").exist?

      IO.popen(["git", "-c", "safe.directory=#{source_dir}", "-C", source_dir.to_s, "rev-parse", "HEAD"], err: File::NULL, &:read).to_s.strip
    rescue Errno::ENOENT
      ""
    end

    def reserve_ids(registry)
      work_identity = "work:#{TARGET_RELATIVE_PATH}"
      work_id = registry.reserve(
        kind: "work",
        identity_key: work_identity,
        path: TARGET_RELATIVE_PATH,
        title: "切韻"
      )

      ids = { work_id: work_id }
      EDITION_ROWS.each do |edition|
        key = edition.fetch(:key)
        label = edition.fetch(:edition_label)
        document_relative_path = Pathname(TARGET_RELATIVE_PATH)
          .join("reconstruction", edition.fetch(:directory_name), edition.fetch(:file))
          .to_s

        ids["#{key}_edition_id".to_sym] = registry.reserve(
          kind: "edition",
          identity_key: "edition:#{TARGET_RELATIVE_PATH}:#{label}",
          path: TARGET_RELATIVE_PATH,
          title: label,
          parent_work_id: work_id
        )
        ids["#{key}_document_id".to_sym] = registry.reserve(
          kind: "document",
          identity_key: "document:#{document_relative_path}",
          path: document_relative_path,
          title: "切韻 (#{label})",
          parent_work_id: work_id
        )
      end
      ids
    end

    def verify_build!(summary, work_root, ids, revision)
      raise Error, "Built work directory missing: #{work_root}" unless work_root.directory?
      raise Error, "Builder reported replacement characters" unless summary.fetch("replacement_characters").to_i.zero?
      raise Error, "Builder reported unusual headwords" unless summary.fetch("unusual_headwords").to_i.zero?

      metadata_path = work_root.join("metadata.json")
      metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
      raise Error, "Metadata work ID mismatch" unless metadata.fetch("work_id") == ids.fetch(:work_id)
      raise Error, "Metadata source revision mismatch" unless metadata.dig("sources", 0, "revision") == revision

      editions = metadata.fetch("editions")
      raise Error, "Expected two Qieyun editions" unless editions.length == 2

      EDITION_ROWS.each_with_index do |edition, index|
        key = edition.fetch(:key)
        metadata_edition = editions.fetch(index)
        raise Error, "Edition ID mismatch for #{edition.fetch(:edition_label)}" unless metadata_edition.fetch("edition_id") == ids.fetch("#{key}_edition_id".to_sym)
        document = metadata_edition.fetch("documents").fetch(0)
        raise Error, "Document ID mismatch for #{edition.fetch(:edition_label)}" unless document.fetch("document_id") == ids.fetch("#{key}_document_id".to_sym)

        text_path = work_root.join("reconstruction", edition.fetch(:directory_name), edition.fetch(:file))
        text = text_path.read(encoding: "UTF-8")
        raise Error, "Invalid Qieyun opening in #{text_path}" unless text.start_with?("平聲\n\n東韻\n\n○")
        raise Error, "Replacement character in #{text_path}" if text.include?("\uFFFD")
        mojibake = ["Ã", "Â", "â€", "ï¿½", "ðŸ"]
        found = mojibake.select { |fragment| text.include?(fragment) }
        raise Error, "Known byte-decoding mojibake in #{text_path}: #{found.join(', ')}" if found.any?
      end
    rescue JSON::ParserError => error
      raise Error, "Generated metadata is invalid JSON: #{error.message}"
    end

    def write_plan(summary, ids, revision, overlay_root, updated_registry, delta_registry)
      text = <<~TEXT
        QIEYUN RESTORED CORPUS INSTALL PLAN
        ===================================

        Source revision: #{revision}
        Target:          #{TARGET_RELATIVE_PATH}
        Work ID:         #{ids.fetch(:work_id)}

        Fujita edition ID:  #{ids.fetch(:fujita_edition_id)}
        Fujita document ID: #{ids.fetch(:fujita_document_id)}
        Li edition ID:      #{ids.fetch(:li_edition_id)}
        Li document ID:     #{ids.fetch(:li_document_id)}

        Fujita rows: #{summary.fetch('editions').find { |row| row.fetch('key') == 'fujita' }.fetch('rows')}
        Li rows:     #{summary.fetch('editions').find { |row| row.fetch('key') == 'li' }.fetch('rows')}

        Corpus overlay:    #{overlay_root}
        Updated registry:  #{updated_registry}
        Registry delta:    #{delta_registry}

        Dry-run by default. Pass --apply to install the corpus folder and replace
        the selected authoritative registry atomically. No routes or database rows
        are changed by this installer.
      TEXT
      output_root.join("INSTALL_PLAN.txt").write(text, encoding: "UTF-8")
    end

    def apply_build!(built_work_root, updated_registry)
      target = corpus_root.join(TARGET_RELATIVE_PATH)
      target_parent = target.dirname
      FileUtils.mkdir_p(target_parent)

      backups = output_root.join("backups")
      FileUtils.mkdir_p(backups)
      registry_backup = backups.join("metadata_id_registry.before_qieyun.csv")
      FileUtils.cp(id_registry_path, registry_backup)

      target_backup = backups.join("切韻.before_install")
      staging = target_parent.join(".切韻.install-#{Process.pid}")
      FileUtils.rm_rf(staging)
      FileUtils.cp_r(built_work_root, staging)

      target_existed = target.exist?
      if target_existed
        FileUtils.rm_rf(target_backup)
        FileUtils.mv(target, target_backup)
      end

      begin
        FileUtils.mv(staging, target)
        atomic_replace(id_registry_path, updated_registry.read(encoding: "UTF-8"))
      rescue StandardError
        FileUtils.rm_rf(target)
        FileUtils.mv(target_backup, target) if target_existed && target_backup.exist?
        atomic_replace(id_registry_path, registry_backup.read(encoding: "UTF-8"))
        raise
      ensure
        FileUtils.rm_rf(staging)
      end
    end

    def atomic_replace(path, content)
      path = Pathname(path)
      temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
      File.open(temp, "w:UTF-8") { |io| io.write(content) }
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if defined?(temp) && temp
    end

    def summary_text(result)
      action = result.fetch("apply") ? "INSTALLED" : "DRY-RUN READY"
      editions = result.fetch("editions")
      <<~TEXT
        QIEYUN RESTORED CORPUS — #{action}
        ==================================
        Target:               #{result['target_relative_path']}
        Source revision:      #{result['source_revision']}
        Work ID:              #{result.dig('ids', 'work_id')}
        Fujita edition rows:  #{editions.find { |row| row['key'] == 'fujita' }['rows']}
        Li edition rows:      #{editions.find { |row| row['key'] == 'li' }['rows']}
        Overlay:              #{result['overlay_root']}
        Updated ID registry:  #{result['updated_registry']}
      TEXT
    end
  end

  module CLI
    module_function

    def run(argv)
      options = { apply: false, replace_existing: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/install_qieyun_restored_corpus.rb --source-dir DIR --corpus-root DIR [options]"
        opts.on("--source-dir DIR", "Extracted or checked-out qieyun-restored source") { |value| options[:source_dir] = value }
        opts.on("--corpus-root DIR", "Corpus root, usually ../corpus") { |value| options[:corpus_root] = value }
        opts.on("--id-registry FILE", "Authoritative metadata_id_registry.csv; newest full_* registry is auto-detected when omitted") { |value| options[:id_registry_path] = value }
        opts.on("--output DIR", "Plan/build output directory") { |value| options[:output_root] = value }
        opts.on("--source-revision SHA", "Exact qieyun-restored source revision") { |value| options[:source_revision] = value }
        opts.on("--apply", "Install the corpus folder and update the authoritative registry") { options[:apply] = true }
        opts.on("--replace-existing", "Allow replacement of an existing 切韻 folder; requires --apply") { options[:replace_existing] = true }
      end
      parser.parse!(argv)

      raise Error, "--source-dir is required" if options[:source_dir].to_s.empty?
      raise Error, "--corpus-root is required" if options[:corpus_root].to_s.empty?
      raise Error, "--replace-existing requires --apply" if options[:replace_existing] && !options[:apply]
      raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      Installer.new(**options).run
      0
    rescue OptionParser::ParseError, Error, QieyunRestoredCorpus::BuildError => error
      warn "Qieyun install failed: #{error.message}"
      warn parser
      2
    end
  end
end

exit QieyunRestoredInstall::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
