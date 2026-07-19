require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "tempfile"

module EditTickets
  class TicketApplier
    def initialize(ticket:, repo_root:, corpus_root:, annotation_items: nil, reviewer_name: nil)
      @ticket = ticket
      @repo_root = Pathname.new(repo_root).expand_path
      @corpus_root = Pathname.new(corpus_root).expand_path
      @annotation_items = annotation_items
      @reviewer_name = reviewer_name.to_s.strip
    end

    def call
      return apply_grammar_entry_ticket! if grammar_entry_ticket?
      return apply_atlas_article_ticket! if atlas_article_ticket?
      return apply_annotation_ticket! if annotation_ticket?
      return apply_companion_material_ticket! if companion_material_ticket?
      return apply_annotation_system_ticket! if annotation_system_ticket?

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

    def grammar_entry_ticket?
      metadata["kind"] == "grammar_entry_submission"
    end

    def apply_grammar_entry_ticket!
      proposed = find_proposed_text_attachment
      raise "No proposed grammar Markdown attachment found." if proposed.nil?

      credit = metadata["credit"].is_a?(Hash) ? metadata["credit"] : {}
      validator = Grammar::SubmissionValidator.new
      result = validator.validate!(
        entry_id: metadata["entry_id"],
        action: metadata["submission_action"],
        locale: metadata["locale"],
        raw_markdown: proposed.blob.download.to_s,
        public_name: credit["name"],
        orcid: credit["orcid"],
        credit_role: credit["role"],
        licence_agreed: true,
        entry_attributes: metadata["catalogue_entry"]
      )

      expected_path = result.target_path.relative_path_from(Rails.root).to_s
      supplied_path = metadata["target_path"].to_s
      unless supplied_path == expected_path
        raise SecurityError, "Grammar ticket target does not match the catalogue"
      end

      Grammar::Publisher.new(reviewer_name: @reviewer_name).publish!(
        entry_id: result.entry.id,
        locale: result.locale,
        proposed_markdown: result.markdown,
        credit: result.credit,
        catalogue_entry: result.catalogue_entry
      )
    rescue Grammar::SubmissionValidator::ValidationError => e
      raise "Grammar ticket is no longer valid: #{e.message}"
    end

    def atlas_article_ticket?
      metadata["kind"] == "atlas_article_submission"
    end

    def apply_atlas_article_ticket!
      proposed = find_proposed_text_attachment
      raise "No proposed atlas Markdown attachment found." if proposed.nil?

      credit = metadata["credit"].is_a?(Hash) ? metadata["credit"] : {}
      result = Atlas::SubmissionValidator.new.validate!(
        entry_id: metadata["entry_id"],
        action: metadata["submission_action"],
        locale: metadata["locale"],
        raw_markdown: proposed.blob.download.to_s,
        public_name: credit["name"],
        orcid: credit["orcid"],
        credit_role: credit["role"],
        licence_agreed: true
      )

      expected_path = result.target_path.relative_path_from(Rails.root).to_s
      supplied_path = metadata["target_path"].to_s
      raise SecurityError, "Atlas ticket target does not match the atlas registry" unless supplied_path == expected_path

      Atlas::Publisher.new(reviewer_name: @reviewer_name).publish!(
        entry_id: result.entry.id,
        locale: result.locale,
        proposed_markdown: result.markdown,
        credit: result.credit
      )
    rescue Atlas::SubmissionValidator::ValidationError => e
      raise "Atlas ticket is no longer valid: #{e.message}"
    end

    def annotation_ticket?
      metadata["kind"] == "annotations_edit"
    end

    def companion_material_ticket?
      metadata["kind"] == "companion_material_submission"
    end

    def annotation_system_ticket?
      %w[annotation_system_submission derived_tradition_submission].include?(metadata["kind"])
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
      record_companion_material!(
        source_path: metadata["source_path"].presence || target_path,
        type: "annotations",
        title: @ticket.title,
        target_path: target_path
      )
    rescue JSON::ParserError => e
      raise "Invalid proposed annotations JSON: #{e.message}"
    end

    def apply_annotation_system_ticket!
      proposed = find_proposed_text_attachment
      raise "No proposed annotation-system text attachment found." if proposed.nil?

      write_proposed_text!(proposed.blob.download)
      record_companion_material!(
        source_path: metadata["source_path"],
        type: "annotation_system",
        title: @ticket.title,
        annotation_system: metadata["annotation_system"].presence || metadata["tradition"],
        target_path: metadata["target_path"]
      )
    end

    def apply_companion_material_ticket!
      if metadata["material_type"] == "translation"
        proposed = find_proposed_text_attachment
        raise "No proposed translation attachment found." if proposed.nil?
        write_proposed_text!(proposed.blob.download)
      end

      record_companion_material!(
        source_path: metadata["source_path"],
        type: metadata["material_type"],
        title: metadata["title"].presence || @ticket.title,
        language_code: metadata["language_code"],
        language_name: metadata["language_name"],
        translator_name: metadata["translator_name"],
        target_path: metadata["target_path"],
        related_path: metadata["related_path"],
        attachments: @ticket.material_files.attachments
      )

      if metadata["material_type"] == "variant_text" && metadata["related_path"].present?
        record_companion_material!(
          source_path: metadata["related_path"],
          type: "variant_text",
          title: metadata["title"].presence || @ticket.title,
          related_path: metadata["source_path"]
        )
      end
    end

    def record_companion_material!(source_path:, type:, title:, annotation_system: nil, language_code: nil, language_name: nil, translator_name: nil, target_path: nil, related_path: nil, attachments: [])
      source_path = source_path.to_s
      raise "Missing source_path for companion material" if source_path.blank?

      material = {
        "id" => metadata["material_id"].presence || @ticket.public_id,
        "type" => type,
        "title" => title,
        "note" => metadata["note"].to_s,
        "provenance" => Array(metadata["provenance"]),
        "references" => metadata["references"],
        "links" => Array(metadata["links"]).map(&:to_s).reject(&:blank?).uniq,
        "evidence_links" => Array(@ticket.evidence_links).map(&:to_s).reject(&:blank?).uniq,
        "language_code" => language_code,
        "language_name" => language_name,
        "translator_name" => translator_name,
        "annotation_system" => annotation_system,
        "target_path" => target_path,
        "related_path" => related_path,
        "ai_assisted" => metadata["ai_assisted"] == true,
        "ai_details" => metadata["ai_details"],
        "ticket_id" => @ticket.public_id
      }

      CorpusCompanionStore.new(source_path: source_path).append(
        material: material,
        attachments: attachments
      )
    end

    def annotation_override_payload
      return nil if @annotation_items.blank?

      items = Array(@annotation_items).filter_map do |item|
        start_idx = value_from(item, :start).to_i
        end_idx = value_from(item, :end).to_i
        next if end_idx <= start_idx

        kind = value_from(item, :kind).to_s
        next unless CorpusAnnotationsStore::KINDS.include?(kind)

        note = value_from(item, :note).to_s.presence
        if kind == "ambiguous_character" && note.blank?
          raise "Ambiguous/disputed character annotations require a note."
        end

        {
          "start" => start_idx,
          "end" => end_idx,
          "kind" => kind,
          "note" => note
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
      result = CorpusSearch::DocumentReader.parse(raw.to_s)
      [result.metadata_entries.any? ? raw.to_s.lines.take(result.metadata_entries.length).join : "", result.body]
    end

    def normalize_ticket_text(text)
      value = text.to_s.dup.force_encoding("UTF-8").scrub
      value.end_with?("\n") ? value : "#{value}\n"
    end

    def extract_corpus_relative_path!
      explicit = metadata["target_path"].to_s
      return explicit if explicit.present?

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
