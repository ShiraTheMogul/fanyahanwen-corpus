#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "tmpdir"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module PrebuiltQieyunInstall
  class Error < StandardError; end

  TARGET_RELATIVE_PATH = "中國漢文/clean/隋朝/隋/切韻"
  EXPECTED_SOURCE_REVISION = "6db59f89004ac747f5e6aa2d54e54bf6f6af2926"
  REQUIRED_REGISTRY_HEADERS = %w[kind id identity_key path title parent_work_id source_document_id status].freeze
  EXPECTED_EDITIONS = {
    "藤田拓海復元本" => {
      directory: "藤田拓海",
      file: "切韻（藤田拓海復元本）.txt"
    },
    "李永富復元本" => {
      directory: "李永富",
      file: "切韻（李永富復元本）.txt"
    }
  }.freeze

  RegistryResult = Struct.new(:path, :headers, :rows, :new_rows, :state, keyword_init: true)

  class Installer
    attr_reader :zip_path, :corpus_root, :registry_path, :output_root, :apply, :replace_existing

    def initialize(zip_path:, corpus_root:, registry_path: nil, output_root: nil, apply: false, replace_existing: false)
      @zip_path = Pathname(normalize_utf8(zip_path)).expand_path
      @corpus_root = Pathname(normalize_utf8(corpus_root)).expand_path
      @registry_path = registry_path && Pathname(normalize_utf8(registry_path)).expand_path
      @output_root = Pathname(normalize_utf8(output_root || default_output_root)).expand_path
      @apply = !!apply
      @replace_existing = !!replace_existing
    end

    def run
      validate_basic_inputs!
      FileUtils.rm_rf(output_root)
      FileUtils.mkdir_p(output_root)

      Dir.mktmpdir("qieyun-prebuilt-") do |tmp|
        extracted_root = extract_and_locate!(Pathname(tmp))
        metadata = validate_payload!(extracted_root)
        expected_rows = registry_rows_from(metadata)
        registry = registry_path ? load_registry(registry_path, expected_rows) : discover_registry(expected_rows)

        overlay_target = output_root.join("corpus_overlay", TARGET_RELATIVE_PATH)
        FileUtils.mkdir_p(overlay_target.dirname)
        FileUtils.cp_r(extracted_root, overlay_target)

        updated_registry = output_root.join("metadata_id_registry.updated.csv")
        delta_registry = output_root.join("metadata_id_registry.qieyun_delta.csv")
        write_registry(registry.headers, registry.rows, updated_registry)
        write_registry(registry.headers, registry.new_rows, delta_registry)
        write_plan(metadata, registry, overlay_target, updated_registry, delta_registry)

        apply_install!(extracted_root, registry.path, updated_registry) if apply

        puts summary(metadata, registry, overlay_target, updated_registry)
      end
    end

    private


    def normalize_utf8(value)
      string = value.to_s.dup
      string.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::ASCII_8BIT
      raise Error, "Invalid UTF-8 path or value: #{value.inspect}" unless string.valid_encoding?
      string
    end

    def default_output_root
      Pathname.pwd.join("tmp/qieyun_prebuilt_install", "plan_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
    end

    def validate_basic_inputs!
      raise Error, "ZIP not found: #{zip_path}" unless zip_path.file?
      raise Error, "Corpus root not found: #{corpus_root}" unless corpus_root.directory?
      raise Error, "--replace-existing requires --apply" if replace_existing && !apply
      raise Error, "Output directory may not be the corpus root" if output_root == corpus_root
    end

    def extract_and_locate!(tmp)
      extractor = <<~PYTHON
        import pathlib
        import sys
        import zipfile

        archive = pathlib.Path(sys.argv[1])
        destination = pathlib.Path(sys.argv[2])
        with zipfile.ZipFile(archive) as handle:
            names = handle.namelist()
            if not names:
                raise SystemExit("ZIP is empty")
            for name in names:
                path = pathlib.PurePosixPath(name)
                if path.is_absolute() or ".." in path.parts:
                    raise SystemExit(f"Unsafe ZIP path: {name!r}")
            handle.extractall(destination)
      PYTHON

      output, status = Open3.capture2e("python3", "-c", extractor, zip_path.to_s, tmp.to_s)
      raise Error, "Could not extract ZIP safely: #{output}" unless status.success?

      candidates = [
        tmp.join("切韻"),
        tmp.join(TARGET_RELATIVE_PATH),
        tmp.join("corpus", TARGET_RELATIVE_PATH)
      ].select { |path| path.join("metadata.json").file? }

      raise Error, "Could not find 切韻/metadata.json in the ZIP" if candidates.empty?
      raise Error, "ZIP contains more than one possible 切韻 payload" if candidates.length > 1
      candidates.first
    rescue Errno::ENOENT
      raise Error, "python3 is required but was not found"
    end

    def validate_payload!(root)
      metadata = JSON.parse(root.join("metadata.json").read(encoding: "UTF-8"))
      raise Error, "Expected title 切韻" unless metadata["title"] == "切韻"
      raise Error, "Expected a positive work_id" unless positive_integer?(metadata["work_id"])
      revision = metadata.dig("sources", 0, "revision")
      raise Error, "Unexpected source revision: #{revision.inspect}" unless revision == EXPECTED_SOURCE_REVISION

      editions = Array(metadata["editions"])
      labels = editions.map { |edition| edition["edition_label"] }
      raise Error, "Expected exactly the two reviewed editions" unless labels.sort == EXPECTED_EDITIONS.keys.sort

      editions.each do |edition|
        label = edition.fetch("edition_label")
        spec = EXPECTED_EDITIONS.fetch(label)
        raise Error, "Expected a positive edition_id for #{label}" unless positive_integer?(edition["edition_id"])
        documents = Array(edition["documents"])
        raise Error, "Expected exactly one document for #{label}" unless documents.length == 1
        document = documents.first
        raise Error, "Expected a positive document_id for #{label}" unless positive_integer?(document["document_id"])

        expected_relative = Pathname("reconstruction").join(spec.fetch(:directory), spec.fetch(:file))
        expected_full = Pathname(TARGET_RELATIVE_PATH).join(expected_relative).to_s
        raise Error, "Document path mismatch for #{label}" unless document["path"] == expected_full

        text_path = root.join(expected_relative)
        raise Error, "Missing text for #{label}: #{text_path}" unless text_path.file?
        text = text_path.read(encoding: "UTF-8")
        raise Error, "Unexpected opening in #{label}" unless text.start_with?("平聲\n\n東韻\n")
        raise Error, "Replacement character in #{label}" if text.include?("\uFFFD")
        mojibake = ["Ã", "Â", "â€", "ï¿½", "ðŸ"].select { |fragment| text.include?(fragment) }
        raise Error, "Known mojibake in #{label}: #{mojibake.join(', ')}" if mojibake.any?
      end

      metadata
    rescue JSON::ParserError => error
      raise Error, "Invalid metadata.json: #{error.message}"
    end

    def registry_rows_from(metadata)
      work_id = Integer(metadata.fetch("work_id"))
      rows = [
        {
          "kind" => "work",
          "id" => work_id,
          "identity_key" => "work:#{TARGET_RELATIVE_PATH}",
          "path" => TARGET_RELATIVE_PATH,
          "title" => "切韻",
          "parent_work_id" => nil,
          "source_document_id" => nil,
          "status" => "active"
        }
      ]

      metadata.fetch("editions").each do |edition|
        label = edition.fetch("edition_label")
        document = edition.fetch("documents").first
        rows << {
          "kind" => "edition",
          "id" => Integer(edition.fetch("edition_id")),
          "identity_key" => "edition:#{TARGET_RELATIVE_PATH}:#{label}",
          "path" => TARGET_RELATIVE_PATH,
          "title" => label,
          "parent_work_id" => work_id,
          "source_document_id" => nil,
          "status" => "active"
        }
        rows << {
          "kind" => "document",
          "id" => Integer(document.fetch("document_id")),
          "identity_key" => "document:#{document.fetch('path')}",
          "path" => document.fetch("path"),
          "title" => document.fetch("title"),
          "parent_work_id" => work_id,
          "source_document_id" => nil,
          "status" => "active"
        }
      end
      rows
    end

    def discover_registry(expected_rows)
      candidates = Dir.glob(Pathname.pwd.join("tmp/**/metadata_id_registry*.csv").to_s)
        .map { |path| Pathname(path) }
        .select(&:file?)
        .reject { |path| path.to_s.include?("/metadata_id_assignment/") || path.to_s.include?("/qieyun_prebuilt_install/") || path.to_s.include?("/qieyun_install/") }
        .sort_by(&:mtime)
        .reverse

      compatible = []
      candidates.each do |candidate|
        begin
          result = load_registry(candidate, expected_rows)
          compatible << result
          break if result.state == "already_registered"
        rescue Error
          next
        end
      end

      return compatible.first if compatible.any?
      raise Error, <<~MSG.strip
        No compatible authoritative registry was found automatically.
        Pass --id-registry FILE explicitly. A compatible pre-install registry must
        have maximum IDs immediately below the IDs carried by this ZIP, or already
        contain the same five identities with the same IDs.
      MSG
    end

    def load_registry(path, expected_rows)
      table = CSV.read(path, headers: true, encoding: "bom|utf-8")
      headers = table.headers.compact.map { |value| normalize_utf8(value) }
      missing = REQUIRED_REGISTRY_HEADERS - headers
      raise Error, "Registry #{path} is missing columns: #{missing.join(', ')}" if missing.any?

      rows = table.map { |row| row.to_h.transform_values { |value| value.nil? ? nil : normalize_utf8(value) } }
      by_identity = {}
      by_id = {}
      maxima = Hash.new(0)
      rows.each do |row|
        kind = row["kind"].to_s
        id = integer_or_nil(row["id"])
        identity = row["identity_key"].to_s
        next if kind.empty? || id.nil?
        maxima[kind] = [maxima[kind], id].max
        by_id[[kind, id]] = row
        by_identity[[kind, identity]] = row unless identity.empty?
      end

      existing_count = 0
      new_rows = []
      expected_rows.each do |expected|
        kind = expected.fetch("kind")
        id = expected.fetch("id")
        identity = expected.fetch("identity_key")
        existing_identity = by_identity[[kind, identity]]
        if existing_identity
          actual_id = integer_or_nil(existing_identity["id"])
          raise Error, "Registry identity #{identity} has ID #{actual_id}, expected #{id}" unless actual_id == id
          existing_count += 1
          next
        end

        existing_id = by_id[[kind, id]]
        raise Error, "Registry #{kind} ID #{id} belongs to #{existing_id['identity_key']}" if existing_id
        new_rows << expected
      end

      state = if existing_count == expected_rows.length
                "already_registered"
              elsif existing_count.positive?
                raise Error, "Registry contains only some of the five Qieyun rows"
              else
                minimums = expected_rows.group_by { |row| row.fetch("kind") }
                  .transform_values { |group| group.map { |row| row.fetch("id") }.min }
                minimums.each do |kind, minimum|
                  expected_max = minimum - 1
                  raise Error, "Registry max #{kind} ID is #{maxima[kind]}, expected #{expected_max}" unless maxima[kind] == expected_max
                end
                "ready_to_append"
              end

      appended = new_rows.map do |expected|
        headers.to_h { |header| [header, expected[header]] }
      end
      RegistryResult.new(
        path: Pathname(path).expand_path,
        headers: headers,
        rows: rows + appended,
        new_rows: appended,
        state: state
      )
    end

    def write_registry(headers, rows, path)
      CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
        rows.each { |row| csv << headers.map { |header| row[header] } }
      end
    end

    def write_plan(metadata, registry, overlay_target, updated_registry, delta_registry)
      text = <<~TEXT
        PREBUILT QIEYUN INSTALL PLAN
        =============================

        ZIP:              #{zip_path}
        Target:           #{TARGET_RELATIVE_PATH}
        Registry:         #{registry.path}
        Registry state:   #{registry.state}
        New registry rows: #{registry.new_rows.length}

        Work ID:          #{metadata.fetch('work_id')}
        Edition IDs:      #{metadata.fetch('editions').map { |row| row.fetch('edition_id') }.join(', ')}
        Document IDs:     #{metadata.fetch('editions').map { |row| row.fetch('documents').first.fetch('document_id') }.join(', ')}

        Corpus overlay:   #{overlay_target}
        Updated registry: #{updated_registry}
        Registry delta:   #{delta_registry}

        Dry-run by default. Pass --apply to install the folder and update the
        selected registry atomically. No routes or database rows are changed.
      TEXT
      output_root.join("INSTALL_PLAN.txt").write(text, encoding: "UTF-8")
    end

    def apply_install!(payload_root, registry, updated_registry)
      target = corpus_root.join(TARGET_RELATIVE_PATH)
      FileUtils.mkdir_p(target.dirname)
      backups = output_root.join("backups")
      FileUtils.mkdir_p(backups)

      registry_backup = backups.join("metadata_id_registry.before_qieyun.csv")
      FileUtils.cp(registry, registry_backup)
      target_backup = backups.join("切韻.before_install")
      staging = target.dirname.join(".切韻.prebuilt-install-#{Process.pid}")
      FileUtils.rm_rf(staging)
      FileUtils.cp_r(payload_root, staging)

      target_existed = target.exist?
      if target_existed
        if same_tree?(target, payload_root)
          FileUtils.rm_rf(staging)
          atomic_replace(registry, updated_registry.read(encoding: "UTF-8"))
          return
        end
        raise Error, "Target already exists and differs: #{target}. Pass --replace-existing after review." unless replace_existing
        FileUtils.rm_rf(target_backup)
        FileUtils.mv(target, target_backup)
      end

      begin
        FileUtils.mv(staging, target)
        atomic_replace(registry, updated_registry.read(encoding: "UTF-8"))
      rescue StandardError
        FileUtils.rm_rf(target)
        FileUtils.mv(target_backup, target) if target_existed && target_backup.exist?
        atomic_replace(registry, registry_backup.read(encoding: "UTF-8"))
        raise
      ensure
        FileUtils.rm_rf(staging)
      end
    end

    def same_tree?(left, right)
      tree_digest(left) == tree_digest(right)
    end

    def tree_digest(root)
      require "digest"
      digest = Digest::SHA256.new
      Dir.glob(root.join("**/*").to_s, File::FNM_DOTMATCH).sort.each do |path_string|
        path = Pathname(path_string)
        next if [".", ".."].include?(path.basename.to_s)
        relative = path.relative_path_from(root).to_s
        digest << relative << "\0"
        digest << (path.file? ? Digest::SHA256.file(path).hexdigest : "directory") << "\0"
      end
      digest.hexdigest
    end

    def atomic_replace(path, content)
      path = Pathname(path)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
      File.open(temporary, "w:UTF-8") { |io| io.write(content) }
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def summary(metadata, registry, overlay_target, updated_registry)
      action = apply ? "INSTALLED" : "DRY-RUN READY"
      <<~TEXT
        PREBUILT QIEYUN — #{action}
        ================================
        Target:             #{TARGET_RELATIVE_PATH}
        Work ID:            #{metadata.fetch('work_id')}
        Edition IDs:        #{metadata.fetch('editions').map { |row| row.fetch('edition_id') }.join(', ')}
        Document IDs:       #{metadata.fetch('editions').map { |row| row.fetch('documents').first.fetch('document_id') }.join(', ')}
        Registry:           #{registry.path}
        Registry state:     #{registry.state}
        New registry rows:  #{registry.new_rows.length}
        Corpus overlay:     #{overlay_target}
        Updated registry:   #{updated_registry}
      TEXT
    end

    def positive_integer?(value)
      Integer(value).positive?
    rescue ArgumentError, TypeError
      false
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end

  module CLI
    module_function

    def run(argv)
      options = { apply: false, replace_existing: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/install_prebuilt_qieyun_zip.rb --zip FILE --corpus-root DIR [options]"
        opts.on("--zip FILE", "Prebuilt 切韻 ZIP") { |value| options[:zip_path] = value }
        opts.on("--corpus-root DIR", "Corpus root, usually ../corpus") { |value| options[:corpus_root] = value }
        opts.on("--id-registry FILE", "Authoritative metadata ID registry; compatible registry is auto-detected when omitted") { |value| options[:registry_path] = value }
        opts.on("--output DIR", "Plan output directory") { |value| options[:output_root] = value }
        opts.on("--apply", "Install the corpus folder and update the registry") { options[:apply] = true }
        opts.on("--replace-existing", "Replace a differing existing 切韻 folder; requires --apply") { options[:replace_existing] = true }
      end
      parser.parse!(argv)
      raise Error, "--zip is required" if options[:zip_path].to_s.empty?
      raise Error, "--corpus-root is required" if options[:corpus_root].to_s.empty?
      raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      Installer.new(**options).run
      0
    rescue OptionParser::ParseError, Error => error
      warn "Prebuilt Qieyun install failed: #{error.message}"
      warn parser
      2
    end
  end
end

exit PrebuiltQieyunInstall::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
