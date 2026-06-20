require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "tempfile"

module EditTickets
  class TicketApplier
    def initialize(ticket:, repo_root:, corpus_root:, annotation_items: nil)
      @ticket = ticket
      @repo_root = Pathname.new(repo_root).expand_path
      @corpus_root = Pathname.new(corpus_root).expand_path
      @annotation_items = annotation_items
    end

    def call
      return apply_annotation_ticket! if annotation_ticket?

      proposed = find_proposed_text_attachment
      return write_proposed_text!(proposed.blob.download) if proposed

      if preserve_front_matter?
        raise "This ticket is missing its proposed text attachment, so applying the body-only diff would clobber metadata. Re-create the ticket after updating the server fix."
      end

      diff_attachment = find_diff_attachment
      raise "No diff attachment found." if diff_attachment.nil?

      apply_unified_diff!(diff_attachment.blob.download)
    end

    private

    def find_diff_attachment
      @ticket.evidence_files.attachments.find do |attachment|
        filename = attachment.blob.filename.to_s
        content_type = attachment.blob.content_type.to_s
        filename.end_with?(".diff") || content_type.include?("diff")
      end
    end

    def find_proposed_text_attachment
      @ticket.evidence_files.attachments.find do |attachment|
        filename = attachment.blob.filename.to_s
        filename.end_with?(".proposed.txt") || filename.include?(".proposed")
      end
    end

    def annotation_ticket?
      metadata["kind"] == "annotations_edit"
    end

    def apply_annotation_ticket!
      target_path = metadata["target_path"].to_s
      raise "Missing target_path for annotation ticket" if target_path.blank?

      parsed = annotation_override_payload
      if parsed.nil?
        proposed = find_proposed_text_attachment
        raise "No proposed annotations attachment found." if proposed.nil?
        parsed = JSON.parse(proposed.blob.download.to_s)
      end

      CorpusAnnotationsStore.new(root: @corpus_root, rel_text_path: target_path).write(parsed)
    rescue JSON::ParserError => e
      raise "Invalid proposed annotations JSON: #{e.message}"
    end

    def annotation_override_payload
      return nil if @annotation_items.blank?

      items = Array(@annotation_items).filter_map do |item|
        start_idx = value_from(item, :start).to_i
        end_idx = value_from(item, :end).to_i
        next if end_idx <= start_idx

        kind = value_from(item, :kind).to_s
        next if kind.blank?

        {
          "start" => start_idx,
          "end" => end_idx,
          "kind" => kind,
          "note" => value_from(item, :note).to_s.presence
        }.compact
      end

      { "version" => 1, "items" => items }
    end

    def write_proposed_text!(raw_text)
      relative_path = extract_corpus_relative_path!
      absolute_path = safe_join_under_root(@corpus_root, relative_path)
      FileUtils.mkdir_p(File.dirname(absolute_path))

      proposed_body = normalize_ticket_text(raw_text)
      final_text = if preserve_front_matter?
        existing_text = File.exist?(absolute_path) ? File.binread(absolute_path).force_encoding("UTF-8").scrub : ""
        front_matter, = split_corpus_front_matter(existing_text)

        if front_matter.present?
          front_matter.rstrip + "\n\n" + proposed_body.sub(/\A\n+/, "")
        else
          proposed_body
        end
      else
        proposed_body
      end

      File.open(absolute_path, "wb:utf-8") { |file| file.write(final_text) }
    end

    def preserve_front_matter?
      metadata["preserve_front_matter"] == true
    end

    def split_corpus_front_matter(raw)
      lines = raw.to_s.lines
      metadata_lines = []
      index = 0

      while index < lines.length && lines[index].start_with?("#")
        metadata_lines << lines[index]
        index += 1
      end

      [metadata_lines.join, lines[index..].join]
    end

    def normalize_ticket_text(text)
      value = text.to_s.dup.force_encoding("UTF-8").scrub
      value.end_with?("\n") ? value : "#{value}\n"
    end

    def extract_corpus_relative_path!
      files = Array(metadata["files"]).map(&:to_s)
      path = files.first.to_s
      raise "Ticket has no diff_metadata files list" if path.blank?
      raise "Diff touches disallowed paths" unless path.start_with?("corpus/")

      path.delete_prefix("corpus/")
    end

    def safe_join_under_root(root_dir, relative_path)
      root = Pathname.new(root_dir).expand_path
      relative = relative_path.to_s.sub(%r{\A/+}, "")
      absolute = root.join(relative).cleanpath

      unless absolute.to_s.start_with?(root.to_s + File::SEPARATOR) || absolute == root
        raise SecurityError, "path escapes root"
      end

      absolute.to_s
    end

    def apply_unified_diff!(diff_text)
      allowed_roots = %w[corpus/ resources/ data/]
      files = Array(metadata["files"]).map(&:to_s)
      raise "Ticket has no diff_metadata files list" if files.empty?
      raise "Diff touches disallowed paths" unless files.all? { |file| allowed_roots.any? { |root| file.start_with?(root) } }

      Tempfile.create(["ticket", ".diff"]) do |tempfile|
        tempfile.binmode
        tempfile.write(diff_text)
        tempfile.flush

        command = ["git", "apply", "--whitespace=nowarn", "-p1", tempfile.path]
        output = nil
        status = nil

        Dir.chdir(@repo_root) do
          output = `#{command.map { |part| Shellwords.escape(part) }.join(" ")} 2>&1`
          status = $?.exitstatus
        end

        raise "git apply failed (#{status}): #{output}" unless status == 0
      end
    end

    def metadata
      @metadata ||= @ticket.diff_metadata.is_a?(Hash) ? @ticket.diff_metadata : {}
    end

    def value_from(item, key)
      item.respond_to?(:[]) ? (item[key] || item[key.to_s]) : nil
    end
  end
end
