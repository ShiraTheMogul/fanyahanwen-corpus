# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"

class CorpusCompanionStore
  VERSION = 1

  def initialize(source_path:, storage_root: Rails.root.join("storage", "corpus_companions"), public_root: Rails.root.join("public", "corpus_companions"))
    @source_path = source_path.to_s.sub(%r{\A/+}, "")
    raise ArgumentError, "source_path is required" if @source_path.blank?

    @storage_root = Pathname.new(storage_root).expand_path
    @public_root = Pathname.new(public_root).expand_path
    @key = Digest::SHA256.hexdigest(@source_path)
  end

  def read
    return empty_payload unless File.file?(manifest_path)

    parsed = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
    return empty_payload unless parsed.is_a?(Hash)

    parsed["version"] = VERSION
    parsed["source_path"] = @source_path
    parsed["materials"] = Array(parsed["materials"])
    parsed
  rescue JSON::ParserError => error
    raise "Invalid companion manifest #{manifest_path}: #{error.message}"
  end

  def append(material:, attachments: [])
    with_manifest_lock do
      payload = read
      row = normalize_material(material)
      row["files"] = promote_files(row["id"], attachments)

      payload["materials"].reject! { |existing| existing["id"].to_s == row["id"].to_s }
      payload["materials"] << row
      payload["updated_at"] = Time.now.utc.iso8601
      atomic_write(payload)
      row
    end
  end

  private

  def empty_payload
    {
      "version" => VERSION,
      "source_path" => @source_path,
      "materials" => [],
      "updated_at" => nil
    }
  end

  def normalize_material(material)
    source = material.respond_to?(:to_h) ? material.to_h : {}
    id = source["id"].to_s
    id = SecureRandom.hex(12) unless id.match?(/\A[0-9A-Za-z_-]+\z/)

    {
      "id" => id,
      "type" => source["type"].to_s,
      "title" => source["title"].to_s.presence,
      "note" => source["note"].to_s,
      "provenance" => Array(source["provenance"]).map(&:to_s).uniq,
      "references" => source["references"].to_s.presence,
      "links" => Array(source["links"]).map(&:to_s).reject(&:blank?).uniq,
      "evidence_links" => Array(source["evidence_links"]).map(&:to_s).reject(&:blank?).uniq,
      "language_code" => source["language_code"].to_s.presence,
      "language_name" => source["language_name"].to_s.presence,
      "translator_name" => source["translator_name"].to_s.presence,
      "annotation_system" => (source["annotation_system"].presence || source["tradition"]).to_s.presence,
      "target_path" => source["target_path"].to_s.presence,
      "related_path" => source["related_path"].to_s.presence,
      "ai_assisted" => source["ai_assisted"] == true,
      "ai_details" => source["ai_details"].to_s.presence,
      "ticket_id" => source["ticket_id"].to_s.presence,
      "created_at" => Time.now.utc.iso8601
    }.compact
  end

  def promote_files(material_id, attachments)
    attachment_list = Array(attachments)
    return [] if attachment_list.empty?

    relative_dir = File.join(@key, material_id)
    absolute_dir = @public_root.join(relative_dir)

    # Applying the same approved ticket twice should replace its permanent
    # copies, not create filename_2, filename_3, and so on.
    FileUtils.rm_rf(absolute_dir)
    FileUtils.mkdir_p(absolute_dir)

    attachment_list.map.with_index do |attachment, index|
      blob = attachment.blob
      filename = safe_filename(blob.filename.to_s, index)
      destination = unique_destination(absolute_dir, filename)
      File.binwrite(destination, blob.download)

      relative_path = Pathname.new(destination).relative_path_from(@public_root).to_s.tr("\\", "/")
      {
        "filename" => File.basename(destination),
        "content_type" => blob.content_type.to_s,
        "byte_size" => blob.byte_size.to_i,
        "url" => "/corpus_companions/#{relative_path}"
      }
    end
  end

  def safe_filename(filename, index)
    base = File.basename(filename.to_s).gsub(/[^\p{L}\p{N}._-]+/u, "_")
    base = "material_#{index + 1}" if base.blank? || %w[. ..].include?(base)
    base
  end

  def unique_destination(directory, filename)
    candidate = directory.join(filename)
    return candidate unless File.exist?(candidate)

    stem = File.basename(filename, File.extname(filename))
    ext = File.extname(filename)
    counter = 2
    loop do
      candidate = directory.join("#{stem}_#{counter}#{ext}")
      return candidate unless File.exist?(candidate)
      counter += 1
    end
  end

  def manifest_path
    @storage_root.join("#{@key}.json")
  end

  def lock_path
    @storage_root.join("#{@key}.lock")
  end

  def with_manifest_lock
    FileUtils.mkdir_p(@storage_root)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end

  def atomic_write(payload)
    FileUtils.mkdir_p(@storage_root)
    tmp = Pathname.new("#{manifest_path}.tmp")
    File.write(tmp, JSON.pretty_generate(payload) + "\n", mode: "w:UTF-8")
    FileUtils.mv(tmp, manifest_path)
  ensure
    FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
  end
end
