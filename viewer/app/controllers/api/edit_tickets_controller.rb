module Api
  class EditTicketsController < ApplicationController
    protect_from_forgery with: :null_session

    before_action :load_ticket, only: %i[show create_message approve reject close download_evidence]
    before_action :load_moderator_token_if_present, only: %i[show index create_message download_evidence resolve_key]
    before_action :require_submitter_key!, only: %i[show create_message download_evidence]
    before_action :require_moderator!, only: %i[index approve reject close]

    # POST /api/tickets
    # Creates a ticket and returns the key ONCE.
    def create
      return create_corpus_submission if params[:kind].to_s == "corpus_submission"
      return create_grammar_entry_submission if params[:kind].to_s == "grammar_entry_submission"
      return create_atlas_article_submission if params[:kind].to_s == "atlas_article_submission"
      return create_annotation_system_submission if %w[annotation_system_submission derived_tradition_submission].include?(params[:kind].to_s)
      return create_companion_material_submission if params[:kind].to_s == "companion_material_submission"

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      diff_file = params[:diff_file]
      uploads = EditTickets::SubmissionExtras.validate_uploads!(
        [diff_file, *Array(params[:evidence_files])].compact
      )

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.strip,
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: params[:source].to_s.strip,
        target_ref: params[:target_ref].to_s.strip,
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current
      )

      if diff_file.present?
        diff_text = diff_file.tempfile.read
        diff_file.tempfile.rewind
        ticket.diff_metadata = EditTickets::UnifiedDiffValidator.validate!(
          diff_text,
          allowed_roots: ["corpus/", "resources/", "data/"]
        )
      end

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: ticket.diff_metadata.present? && ticket.diff_metadata["file_count"].to_i.positive?,
        has_uploads: uploads.any?,
        link_count: ticket.evidence_links.size
      )

      ticket.transaction do
        ticket.save!
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: { source: ticket.source, target_ref: ticket.target_ref, tags: ticket.tags }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: { id: ticket.public_id, status: ticket.status, tags: ticket.tags },
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    end

    # POST /api/tickets/text_edit
    #
    # Create a ticket for a corpus text edit.
    # The client submits the edited text; the server loads the current file,
    # generates a unified diff, and stores that diff as an evidence file.
    def create_text_edit
      source = params[:source].presence || "corpus_viewer"
      target_path = params[:target_path].to_s
      new_text = params[:new_text].to_s

      return create_metadata_fields_edit(source: source, target_path: target_path) if params[:edit_mode].to_s == "metadata_fields"

      return render(json: { ok: false, error: "target_path is required" }, status: 422) if target_path.blank?
      return render(json: { ok: false, error: "new_text is required" }, status: 422) if new_text.blank?

      corpus_root = Rails.configuration.x.corpus_root
      corpus_root = Rails.root.join("..", "corpus") if corpus_root.to_s.strip.empty?

      fs_path = safe_join_under_root(corpus_root, target_path)
      return render(json: { ok: false, error: "Not a file" }, status: 422) unless File.file?(fs_path)

      old_text = File.binread(fs_path).force_encoding("UTF-8").scrub
      old_body = CorpusSearch::DocumentReader.parse(old_text).body
      normalized_new_text = normalize_ticket_text(new_text)
      normalized_old_body = normalize_ticket_text(old_body)

      # JSON metadata is the source of truth now. Text edits edit the whole .txt
      # body file; metadata edits target metadata.json directly.
      patch_path = "corpus/#{target_path}"

      diff_text = unified_diff_via_git(normalized_old_body, normalized_new_text, patch_path)
      return render(json: { ok: false, error: "No changes detected" }, status: 422) if diff_text.blank?

      metadata = EditTickets::UnifiedDiffValidator.validate!(
        diff_text,
        allowed_roots: ["corpus/"]
      )
      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.presence || "Text edit",
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: source,
        target_ref: "#{source}/#{target_path}#1",
        status: "open",
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: metadata.merge(
          "edit_mode" => target_path.end_with?("metadata.json") ? "metadata_json" : "body_only",
          "target_path" => target_path,
          "preserve_front_matter" => false
        )
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: links.size
      )

      ticket.transaction do
        ticket.save!
        # Attach both files in one call. Repeated has_many_attached#attach calls here
        # have proven unreliable in this flow, and we must keep the proposed body text
        # so moderator application can preserve existing file metadata/front matter.
        ticket.evidence_files.attach([
          {
            io: StringIO.new(diff_text),
            filename: "text_edit_#{File.basename(target_path)}.diff",
            content_type: "text/x-diff"
          },
          {
            io: StringIO.new(normalized_new_text),
            filename: "text_edit_#{File.basename(target_path)}.proposed.txt",
            content_type: "text/plain"
          }
        ])
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: { source: ticket.source, target_ref: ticket.target_ref, tags: ticket.tags, kind: "text_edit" }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad path" }, status: 400
    rescue => e
      Rails.logger.error("[create_text_edit] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    # POST /api/tickets/resolve_key
    #
    # Resolve a submitter key to its ticket so the public access UI can work
    # with the key alone. This scans tickets server-side and returns the first
    # matching ticket. That is acceptable here because ticket keys are high-entropy
    # random secrets and the system is expected to have a manageable ticket count.
    def resolve_key
      return if performed?

      key = request.get_header("HTTP_X_TICKET_KEY").to_s
      key = params[:ticket_key].to_s if key.blank?
      key = params.dig(:ticket, :ticket_key).to_s if key.blank?

      if key.blank?
        render json: { ok: false, error: "ticket key required" }, status: 422
        return
      end

      ticket = nil
      EditTicket.order(created_at: :desc).find_each(batch_size: 200) do |candidate|
        if EditTickets::KeyManager.valid?(candidate.key_digest, key, candidate.key_salt)
          ticket = candidate
          break
        end
      end

      unless ticket
        render json: {
          ok: false,
          error: "invalid ticket key",
          hint: "If your submission is blocked by security limits, you can always open a GitHub Issue instead."
        }, status: 401
        return
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket)
      }
    end

    # GET /api/tickets/:public_id
    def index
      # Moderator-only listing endpoint.
      # Optional filters: status, tag
      status = params[:status].presence
      tag = params[:tag].presence

      scope = EditTicket.all.order(created_at: :desc)
      scope = scope.where(status: status) if status
      tickets = scope.limit(200).select(:public_id, :status, :tags, :title, :summary, :source, :target_ref, :created_at, :updated_at)
      if tag
        tickets = tickets.select { |t| Array(t.tags).map(&:to_s).include?(tag) }
      end
      tickets = tickets.first(100)

      render json: {
        ok: true,
        tickets: tickets.map { |t| {
          id: t.public_id,
          status: t.status,
          title: t.title,
          summary: t.summary,
          source: t.source,
          target_ref: t.target_ref,
          tags: t.tags,
          created_at: t.created_at,
          updated_at: t.updated_at,
        } },
      }
    end

    def show
      render json: {
        ok: true,
        ticket_id: @ticket.public_id,
        ticket: ticket_json(@ticket)
      }
    end

    # POST /api/tickets/:public_id/messages
    def create_message
      body = params[:body].to_s
      raise ArgumentError, "message is empty" if body.strip.empty?

      msg = @ticket.ticket_messages.create!(
        body: body,
        actor_type: "submitter",
        actor_label: "submitter",
        created_at: Time.current
      )

      EditTickets::AuditLogger.log!(
        ticket: @ticket,
        action: "message_posted",
        actor_type: "submitter",
        metadata: { message_id: msg.id }
      )

      render json: { ok: true, message_id: msg.id }, status: 201
    rescue ArgumentError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    end

    # POST /api/tickets/:public_id/approve
    def approve
      EditTickets::TicketApplier.new(
        ticket: @ticket,
        repo_root: ticket_repo_root,
        corpus_root: ticket_corpus_root,
        reviewer_name: @moderator.name
      ).call

      %w[ticket_approved ticket_applied].each do |action|
        EditTickets::AuditLogger.log!(
          ticket: @ticket,
          action: action,
          actor_type: "moderator_token",
          actor_id: @moderator.id,
          actor_label: @moderator.name,
          metadata: { scope: @moderator.scope }
        )
      end

      @ticket.update!(status: "applied")
      render json: { ok: true, status: @ticket.status }
    rescue => e
      render json: { ok: false, error: e.message }, status: 422
    end

    # POST /api/tickets/:public_id/reject
    def reject
      reason = params[:reason].to_s
      @ticket.update!(status: "rejected")
      EditTickets::AuditLogger.log!(
        ticket: @ticket,
        action: "ticket_rejected",
        actor_type: "moderator_token",
        actor_id: @moderator.id,
        actor_label: @moderator.name,
        metadata: { scope: @moderator.scope, reason: reason }
      )
      render json: { ok: true }
    end

    # POST /api/tickets/:public_id/close
    def close
      @ticket.close!
      EditTickets::AuditLogger.log!(
        ticket: @ticket,
        action: "ticket_closed",
        actor_type: "moderator_token",
        actor_id: @moderator.id,
        actor_label: @moderator.name,
        metadata: { scope: @moderator.scope }
      )

      # Privacy: delete contact immediately when ticket is closed.
      @ticket.ticket_contact&.destroy!

      render json: { ok: true, contact_deleted: true }
    end

    # GET /api/tickets/:public_id/evidence/:attachment_id
    def download_evidence
      attachment = (@ticket.evidence_files.attachments.to_a + @ticket.material_files.attachments.to_a).find { |item| item.id.to_s == params[:attachment_id].to_s }
      raise ActiveRecord::RecordNotFound if attachment.nil?
      blob = attachment.blob

      send_data(
        blob.download,
        filename: blob.filename.to_s,
        type: blob.content_type,
        disposition: "attachment"
      )
    rescue ActiveRecord::RecordNotFound
      render json: { ok: false, error: "not found" }, status: 404
    end

    private

    def create_grammar_entry_submission
      validator = Grammar::SubmissionValidator.new
      entry_attributes = if params[:unlisted_entry].to_s == "1"
                           {
                             "kind" => params[:entry_kind],
                             "headword" => params[:entry_headword],
                             "title" => params[:entry_title],
                             "parent_id" => params[:entry_parent_id],
                             "label" => params[:entry_label]
                           }
                         end
      result = validator.validate!(
        entry_id: params[:entry_id],
        action: params[:submission_action],
        locale: params[:locale],
        raw_markdown: params[:raw_markdown],
        public_name: params[:public_name],
        orcid: params[:orcid],
        credit_role: params[:credit_role],
        licence_agreed: params[:licence_agreed],
        entry_attributes: entry_attributes
      )

      target_path = result.target_path.relative_path_from(Rails.root).to_s
      old_markdown = result.target_path.file? ? result.target_path.binread.force_encoding("UTF-8").scrub : ""
      diff_text = unified_diff_via_git(old_markdown, result.markdown, target_path)
      return render(json: { ok: false, error: "No changes detected" }, status: 422) if diff_text.blank?

      validated_diff = EditTickets::UnifiedDiffValidator.validate!(
        diff_text,
        allowed_roots: ["content/grammar/"]
      )
      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.presence || "Grammar Wiki: #{result.entry.title}",
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: params[:source].to_s.presence || "grammar_wiki",
        target_ref: "grammar/#{result.entry.id}?locale=#{result.locale}",
        status: "open",
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: validated_diff.merge(
          "kind" => "grammar_entry_submission",
          "submission_action" => result.action,
          "entry_id" => result.entry.id,
          "entry_kind" => result.entry.kind,
          "entry_title" => result.entry.title,
          "locale" => result.locale,
          "target_path" => target_path,
          "credit" => result.credit,
          "licence" => "CC BY",
          "catalogue_entry" => result.catalogue_entry
        )
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: links.size,
        material_type: "grammar_article"
      )

      safe_name = result.entry.id.gsub(/[^a-z0-9-]/i, "-")
      ticket.transaction do
        ticket.save!
        ticket.evidence_files.attach([
          {
            io: StringIO.new(diff_text),
            filename: "grammar_#{safe_name}_#{result.locale}.diff",
            content_type: "text/x-diff"
          },
          {
            io: StringIO.new(result.markdown),
            filename: "grammar_#{safe_name}_#{result.locale}.proposed.md",
            content_type: "text/markdown"
          }
        ])
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: {
            source: ticket.source,
            target_ref: ticket.target_ref,
            tags: ticket.tags,
            kind: "grammar_entry_submission",
            submission_action: result.action,
            entry_id: result.entry.id,
            locale: result.locale
          }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue Grammar::SubmissionValidator::ValidationError,
           EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad grammar article path" }, status: 400
    rescue => e
      Rails.logger.error("[create_grammar_entry_submission] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    def create_atlas_article_submission
      result = Atlas::SubmissionValidator.new.validate!(
        entry_id: params[:entry_id],
        action: params[:submission_action],
        locale: params[:locale],
        raw_markdown: params[:raw_markdown],
        public_name: params[:public_name],
        orcid: params[:orcid],
        credit_role: params[:credit_role],
        licence_agreed: params[:licence_agreed]
      )

      target_path = result.target_path.relative_path_from(Rails.root).to_s
      old_markdown = result.target_path.file? ? result.target_path.binread.force_encoding("UTF-8").scrub : ""
      diff_text = unified_diff_via_git(old_markdown, result.markdown, target_path)
      return render(json: { ok: false, error: "No changes detected" }, status: 422) if diff_text.blank?

      validated_diff = EditTickets::UnifiedDiffValidator.validate!(
        diff_text,
        allowed_roots: ["content/atlas/"]
      )
      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.presence || "Atlas: #{result.entry.title}",
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: params[:source].to_s.presence || "historical_atlas",
        target_ref: "atlas/#{result.entry.id}?locale=#{result.locale}",
        status: "open",
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: validated_diff.merge(
          "kind" => "atlas_article_submission",
          "submission_action" => result.action,
          "entry_id" => result.entry.id,
          "entry_title" => result.entry.title,
          "locale" => result.locale,
          "target_path" => target_path,
          "credit" => result.credit,
          "licence" => "CC BY"
        )
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: links.size,
        material_type: "atlas_article"
      )

      safe_name = result.entry.id.gsub(/[^a-z0-9-]/i, "-")
      ticket.transaction do
        ticket.save!
        ticket.evidence_files.attach([
          {
            io: StringIO.new(diff_text),
            filename: "atlas_#{safe_name}_#{result.locale}.diff",
            content_type: "text/x-diff"
          },
          {
            io: StringIO.new(result.markdown),
            filename: "atlas_#{safe_name}_#{result.locale}.proposed.md",
            content_type: "text/markdown"
          }
        ])
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: {
            source: ticket.source,
            target_ref: ticket.target_ref,
            tags: ticket.tags,
            kind: "atlas_article_submission",
            submission_action: result.action,
            entry_id: result.entry.id,
            locale: result.locale
          }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue Atlas::SubmissionValidator::ValidationError,
           EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad atlas article path" }, status: 400
    rescue => e
      Rails.logger.error("[create_atlas_article_submission] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    def create_metadata_fields_edit(source:, target_path:)
      return render(json: { ok: false, error: "target_path is required" }, status: 422) if target_path.blank?
      return render(json: { ok: false, error: "Metadata edits must target metadata.json" }, status: 422) unless File.basename(target_path) == "metadata.json"

      corpus_root = ticket_corpus_root
      fs_path = safe_join_under_root(corpus_root, target_path)
      return render(json: { ok: false, error: "metadata.json not found" }, status: 422) unless File.file?(fs_path)

      old_text = File.binread(fs_path).force_encoding("UTF-8").scrub
      old_payload = JSON.parse(old_text)
      new_payload = update_metadata_payload_from_fields(old_payload, params)
      normalized_old = normalize_ticket_text(JSON.pretty_generate(old_payload))
      normalized_new = normalize_ticket_text(JSON.pretty_generate(new_payload))

      diff_text = unified_diff_via_git(normalized_old, normalized_new, "corpus/#{target_path}")
      return render(json: { ok: false, error: "No changes detected" }, status: 422) if diff_text.blank?

      metadata = EditTickets::UnifiedDiffValidator.validate!(diff_text, allowed_roots: ["corpus/"])
      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.presence || "Metadata edit",
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: source,
        target_ref: "#{source}/#{target_path}#metadata",
        status: "open",
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: metadata.merge(
          "edit_mode" => "metadata_fields",
          "target_path" => target_path,
          "preserve_front_matter" => false
        )
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: links.size
      )

      ticket.transaction do
        ticket.save!
        ticket.evidence_files.attach([
          {
            io: StringIO.new(diff_text),
            filename: "metadata_edit_#{File.basename(File.dirname(target_path))}.diff",
            content_type: "text/x-diff"
          },
          {
            io: StringIO.new(normalized_new),
            filename: "metadata_edit_#{File.basename(File.dirname(target_path))}.proposed.json",
            content_type: "application/json"
          }
        ])
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: { source: ticket.source, target_ref: ticket.target_ref, tags: ticket.tags, kind: "metadata_fields_edit" }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue JSON::ParserError => e
      render json: { ok: false, error: "Invalid metadata.json: #{e.message}" }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad path" }, status: 400
    rescue => e
      Rails.logger.error("[create_metadata_fields_edit] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    def create_companion_material_submission
      source = params[:source].presence || "corpus_viewer"
      base_path = params[:base_path].to_s.strip.sub(%r{\A/+}, "")
      material_type = params[:material_type].to_s.strip
      allowed_types = %w[translation gallery_image exemplar_manuscript variant_text]

      return render(json: { ok: false, error: "base_path is required" }, status: 422) if base_path.blank?
      return render(json: { ok: false, error: "invalid material type" }, status: 422) unless allowed_types.include?(material_type)
      return render(json: { ok: false, error: "Choose the source page, not a derived or translation file" }, status: 422) if companion_segment_in_path?(base_path)

      corpus_root = ticket_corpus_root
      base_abs = safe_join_under_root(corpus_root, base_path)
      return render(json: { ok: false, error: "Source page not found" }, status: 422) unless File.file?(base_abs)

      material_metadata = EditTickets::MaterialMetadata.build!(params)
      material_links = EditTickets::SubmissionExtras.evidence_links(params[:material_links])
      evidence_links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      material_uploads = Array(params[:material_files]).compact
      evidence_uploads = Array(params[:evidence_files]).compact
      EditTickets::SubmissionExtras.validate_uploads!(material_uploads + evidence_uploads)

      if material_uploads.any? && !%w[gallery_image exemplar_manuscript].include?(material_type)
        return render(json: { ok: false, error: "Material files are only accepted for gallery images and exemplar manuscripts; use evidence files for supporting documents" }, status: 422)
      end

      invalid_material_upload = material_uploads.find do |upload|
        !%w[.png .jpg .jpeg .pdf].include?(File.extname(upload.original_filename.to_s).downcase)
      end
      if invalid_material_upload
        return render(json: { ok: false, error: "Permanent material files must be PNG, JPEG, or PDF" }, status: 422)
      end

      material_id = SecureRandom.hex(12)
      material_title = params[:material_title].to_s.strip
      related_path = params[:related_path].to_s.strip.sub(%r{\A/+}, "")
      language_code = nil
      language_name = nil
      translator_name = nil
      target_rel = nil
      diff_text = nil
      proposed_text = nil

      case material_type
      when "translation"
        language_code = params[:language_code].to_s.strip.downcase
        return render(json: { ok: false, error: "Choose a valid ISO 639-3 language" }, status: 422) unless IsoLanguageRegistry.include?(language_code)

        language_name = IsoLanguageRegistry.name_for(language_code)
        translator_name = params[:translator_name].to_s.strip.presence
        proposed_text = normalize_ticket_text(params[:body_text].to_s)
        return render(json: { ok: false, error: "translation text is required" }, status: 422) if proposed_text.strip.blank?

        dir = File.dirname(base_path)
        dir = nil if dir == "."
        base = File.basename(base_path)
        target_rel = [dir, "translation", language_code, material_id, base].reject(&:blank?).join("/")
        diff_text = unified_diff_via_git("", proposed_text, "corpus/#{target_rel}")
      when "gallery_image", "exemplar_manuscript"
        if material_uploads.empty? && material_links.empty?
          return render(json: { ok: false, error: "Add at least one material file or material link" }, status: 422)
        end
      when "variant_text"
        if related_path.blank? && material_links.empty?
          return render(json: { ok: false, error: "Add a related corpus path or material link" }, status: 422)
        end

        if related_path.present?
          return render(json: { ok: false, error: "A text cannot be its own variant" }, status: 422) if related_path == base_path
          return render(json: { ok: false, error: "Choose a source corpus text, not a translation or annotation-system file" }, status: 422) if companion_segment_in_path?(related_path)

          related_abs = safe_join_under_root(corpus_root, related_path)
          return render(json: { ok: false, error: "Related corpus file not found" }, status: 422) unless File.file?(related_abs)
        end
      end

      diff_metadata = {
        "kind" => "companion_material_submission",
        "material_id" => material_id,
        "material_type" => material_type,
        "source_path" => base_path,
        "title" => material_title.presence,
        "links" => material_links,
        "related_path" => related_path.presence,
        "language_code" => language_code,
        "language_name" => language_name,
        "translator_name" => translator_name,
        "target_path" => target_rel,
        "material_file_count" => material_uploads.length
      }.merge(material_metadata).compact

      if diff_text.present?
        validated = EditTickets::UnifiedDiffValidator.validate!(diff_text, allowed_roots: ["corpus/"])
        diff_metadata = validated.merge(diff_metadata)
      end

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.presence || companion_ticket_title(material_type, language_name),
        summary: params[:summary].to_s.presence || material_metadata["note"],
        reasoning: params[:reasoning].to_s,
        source: source,
        target_ref: "#{source}/#{base_path}#companion",
        status: "open",
        evidence_links: evidence_links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: diff_metadata
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: diff_text.present?,
        has_uploads: material_uploads.any? || evidence_uploads.any?,
        link_count: evidence_links.size + material_links.size,
        material_type: material_type
      )

      ticket.transaction do
        ticket.save!

        if diff_text.present?
          ticket.evidence_files.attach([
            {
              io: StringIO.new(diff_text),
              filename: "translation_#{language_code}_#{material_id}.diff",
              content_type: "text/x-diff"
            },
            {
              io: StringIO.new(proposed_text),
              filename: "translation_#{language_code}_#{material_id}.proposed.txt",
              content_type: "text/plain"
            }
          ])
        end

        EditTickets::SubmissionExtras.attach_uploads!(ticket, evidence_uploads)
        material_uploads.each { |upload| ticket.material_files.attach(upload) }
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: {
            source: ticket.source,
            target_ref: ticket.target_ref,
            tags: ticket.tags,
            kind: "companion_material_submission",
            material_type: material_type
          }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue EditTickets::MaterialMetadata::ValidationError,
           EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad path" }, status: 400
    rescue => e
      Rails.logger.error("[create_companion_material_submission] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    def create_corpus_submission
      source = params[:source].presence || "corpus_submission"
      parent_path = params[:parent_path].to_s.strip.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      work_folder = params[:work_folder].to_s.strip
      file_name = params[:file_name].to_s.strip
      page_mode = params[:page_mode].to_s == "multi" ? "multi" : "single"

      return render(json: { ok: false, error: "parent_path is required" }, status: 422) if parent_path.blank?
      return render(json: { ok: false, error: "work_folder is required" }, status: 422) if work_folder.blank?

      corpus_root = Rails.configuration.x.corpus_root
      corpus_root = Rails.root.join("..", "corpus") if corpus_root.to_s.strip.empty?

      parent_abs = safe_join_under_root(corpus_root, parent_path)
      return render(json: { ok: false, error: "Parent directory not found" }, status: 422) unless File.directory?(parent_abs)
      return render(json: { ok: false, error: "Submissions must go inside a clean directory" }, status: 422) unless clean_submission_directory?(parent_path)

      work_folder = sanitize_submission_segment(work_folder)
      return render(json: { ok: false, error: "work_folder contains forbidden path characters" }, status: 422) if work_folder.blank?

      target_dir_rel = [parent_path, work_folder].reject(&:blank?).join("/")
      target_dir_abs = safe_join_under_root(corpus_root, target_dir_rel)

      nation = params[:nation].to_s.strip
      work_title = params[:work_title].to_s.strip
      author = params[:author].to_s.strip
      source_citation = params[:source_citation].to_s.strip
      url = params[:url].to_s.strip
      date_label = params[:date_label].to_s.strip
      period = params[:period].to_s.strip
      polity = params[:polity].to_s.strip
      region = params[:region].to_s.strip
      categories = split_metadata_list(params[:categories])
      text_type = permitted_text_type(params[:text_type]) || "source"
      context_details = params[:context_details].to_s
      title = params[:title].to_s.presence || "Corpus text submission"
      summary = params[:summary].to_s
      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])

      ticket_files = []
      preview_rows = []

      if page_mode == "multi"
        raw_pages = params[:pages]
        raw_pages = JSON.parse(raw_pages) if raw_pages.is_a?(String)
        pages = Array(raw_pages).map.with_index do |page, idx|
          item = page.respond_to?(:to_h) ? page.to_h : {}
          {
            "label" => item["label"].to_s.strip,
            "body" => item["body"].to_s
          }
        end.select { |row| row["body"].to_s.strip.present? }

        return render(json: { ok: false, error: "Add at least one page with text" }, status: 422) if pages.empty?

        pages.each_with_index do |page, idx|
          seq = idx + 1
          file_parts = [target_dir_rel]
          file_parts << text_type unless text_type == "source"
          file_parts << format("%s__juan_%04d.txt", work_folder, seq)
          file_rel = file_parts.join("/")
          file_abs = safe_join_under_root(corpus_root, file_rel)
          return render(json: { ok: false, error: "A file already exists at #{file_rel}" }, status: 422) if File.exist?(file_abs)

          label = page["label"].presence || format("卷%03d", seq)
          page_title = work_title.present? ? "#{work_title}/#{label}" : label
          final_text = build_submission_text(
            nation: nation,
            work_title: work_title,
            author: author,
            page_title: page_title,
            source_citation: source_citation,
            url: url,
            body: page["body"]
          )

          ticket_files << { path: "corpus/#{file_rel}", text: final_text }
          preview_rows << { "path" => file_rel, "page_title" => page_title, "chars" => page["body"].to_s.length }
        end
      else
        file_name = sanitize_submission_filename(file_name.presence || "#{work_folder}.txt")
        return render(json: { ok: false, error: "file_name is invalid" }, status: 422) if file_name.blank?

        body = params[:body].to_s
        return render(json: { ok: false, error: "body is required" }, status: 422) if body.strip.blank?

        file_parts = [target_dir_rel]
        file_parts << text_type unless text_type == "source"
        file_parts << file_name
        file_rel = file_parts.join("/")
        file_abs = safe_join_under_root(corpus_root, file_rel)
        return render(json: { ok: false, error: "A file already exists at #{file_rel}" }, status: 422) if File.exist?(file_abs)

        page_title = params[:page_title].to_s.strip
        final_text = build_submission_text(
          nation: nation,
          work_title: work_title,
          author: author,
          page_title: page_title,
          source_citation: source_citation,
          url: url,
          body: body
        )

        ticket_files << { path: "corpus/#{file_rel}", text: final_text }
        preview_rows << { "path" => file_rel, "page_title" => page_title, "chars" => body.length }
      end

      metadata_json = build_submission_metadata_json(
        target_dir_rel: target_dir_rel,
        work_folder: work_folder,
        nation: nation,
        work_title: work_title,
        author: author,
        source_citation: source_citation,
        url: url,
        date_label: date_label,
        period: period,
        polity: polity,
        region: region,
        categories: categories,
        preview_rows: preview_rows,
        text_type: text_type
      )
      ticket_files << { path: "corpus/#{target_dir_rel}/metadata.json", text: metadata_json }

      diff_text = ticket_files.map { |row| unified_diff_via_git("", row[:text], row[:path]) }.reject(&:blank?).join("\n")
      return render(json: { ok: false, error: "No changes detected" }, status: 422) if diff_text.blank?

      metadata = EditTickets::UnifiedDiffValidator.validate!(
        diff_text,
        allowed_roots: ["corpus/"]
      )

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: title,
        summary: summary,
        reasoning: context_details,
        source: source,
        target_ref: "#{source}/#{target_dir_rel}",
        status: "open",
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: metadata.merge(
          "kind" => "corpus_submission",
          "target_directory" => target_dir_rel,
          "work_folder" => work_folder,
          "page_mode" => page_mode,
          "page_count" => ticket_files.length,
          "text_type" => text_type,
          "preview_files" => preview_rows,
          "metadata_preview" => {
            "nation" => nation,
            "work_title" => work_title,
            "author" => author,
            "source" => source_citation,
            "url" => url,
            "date_label" => date_label,
            "period" => period,
            "polity" => polity,
            "region" => region,
            "categories" => categories
          }
        )
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: links.size
      )

      manifest_lines = [
        "Corpus submission ticket",
        "Target directory: #{target_dir_rel}",
        "Work folder: #{work_folder}",
        "Page mode: #{page_mode}",
        "Page count: #{ticket_files.length}",
        "",
        "Metadata preview:",
        "NATION: #{nation}",
        "WORK_TITLE: #{work_title}",
        "AUTHOR: #{author}",
        "SOURCE: #{source_citation}",
        "URL: #{url}",
        "DATE: #{date_label}",
        "PERIOD: #{period}",
        "POLITY: #{polity}",
        "REGION: #{region}",
        "CATEGORIES: #{categories.join('; ')}",
        "TEXT TYPE: #{text_type}",
        "",
        "Files:",
        *preview_rows.map { |row| "- #{row['path']}#{row['page_title'].present? ? " (#{row['page_title']})" : ""}" }
      ].join("\n") + "\n"

      ticket.transaction do
        ticket.save!
        ticket.evidence_files.attach({
          io: StringIO.new(diff_text),
          filename: "corpus_submission_#{work_folder}.diff",
          content_type: "text/x-diff"
        })
        ticket.evidence_files.attach({
          io: StringIO.new(manifest_lines),
          filename: "corpus_submission_#{work_folder}.manifest.txt",
          content_type: "text/plain"
        })
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: { source: ticket.source, target_ref: ticket.target_ref, tags: ticket.tags, kind: "corpus_submission" }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue JSON::ParserError
      render json: { ok: false, error: "invalid JSON in pages" }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad path" }, status: 400
    rescue => e
      Rails.logger.error("[create_corpus_submission] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    def create_annotation_system_submission
      source = params[:source].presence || "corpus_viewer"
      base_path = params[:base_path].to_s.strip.sub(%r{\A/+}, "")
      annotation_system = permitted_annotation_system(params[:annotation_system].presence || params[:tradition])
      body_text = params[:body_text].to_s
      generation_mode = params[:generation_mode].to_s.presence || "manual"
      material_metadata = EditTickets::MaterialMetadata.build!(params)
      links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
      uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])

      return render(json: { ok: false, error: "base_path is required" }, status: 422) if base_path.blank?
      return render(json: { ok: false, error: "annotation_system must be kanbun, hanmun, or hanvan" }, status: 422) unless annotation_system.present?
      return render(json: { ok: false, error: "body_text is required" }, status: 422) if body_text.strip.blank?
      return render(json: { ok: false, error: "Choose a source page, not an existing annotation-system file" }, status: 422) if annotation_system_segment_in_path?(base_path)

      corpus_root = Rails.configuration.x.corpus_root
      corpus_root = Rails.root.join("..", "corpus") if corpus_root.to_s.strip.empty?

      base_abs = safe_join_under_root(corpus_root, base_path)
      return render(json: { ok: false, error: "Source page not found" }, status: 422) unless File.file?(base_abs)

      target_rel = annotation_system_target_rel_path(base_path, annotation_system)
      target_abs = safe_join_under_root(corpus_root, target_rel)

      old_text = File.file?(target_abs) ? File.binread(target_abs).force_encoding("UTF-8").scrub : ""
      old_text = normalize_ticket_text(split_corpus_front_matter(old_text).last)
      new_text = normalize_ticket_text(body_text)

      diff_text = unified_diff_via_git(old_text, new_text, "corpus/#{target_rel}")
      return render(json: { ok: false, error: "No changes detected" }, status: 422) if diff_text.blank?

      metadata = EditTickets::UnifiedDiffValidator.validate!(
        diff_text,
        allowed_roots: ["corpus/"]
      )

      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      ticket = EditTicket.new(
        public_id: SecureRandom.hex(12),
        title: params[:title].to_s.presence || "Create annotation system: #{annotation_system.titleize}",
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: source,
        target_ref: "#{source}/#{target_rel}",
        status: "open",
        evidence_links: links,
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: metadata.merge(
          "kind" => "annotation_system_submission",
          "target_path" => target_rel,
          "source_path" => base_path,
          "annotation_system" => annotation_system,
          "preserve_front_matter" => false,
          "generation_mode" => generation_mode
        ).merge(material_metadata)
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: links.size,
        material_type: "annotation_system"
      )

      ticket.transaction do
        ticket.save!
        ticket.evidence_files.attach([
          {
            io: StringIO.new(diff_text),
            filename: "#{annotation_system}_#{File.basename(base_path)}.diff",
            content_type: "text/x-diff"
          },
          {
            io: StringIO.new(new_text),
            filename: "#{annotation_system}_#{File.basename(base_path, ".txt")}.proposed.txt",
            content_type: "text/plain"
          }
        ])
        EditTickets::SubmissionExtras.attach_uploads!(ticket, uploads)
        EditTickets::SubmissionExtras.create_contact!(ticket, params[:contact])
        EditTickets::AuditLogger.log!(
          ticket: ticket,
          action: "ticket_created",
          actor_type: "submitter",
          metadata: { source: ticket.source, target_ref: ticket.target_ref, tags: ticket.tags, kind: "annotation_system_submission", annotation_system: annotation_system, generation_mode: generation_mode }
        )
      end

      render json: {
        ok: true,
        ticket_id: ticket.public_id,
        ticket: ticket_json(ticket),
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
      }, status: 201
    rescue EditTickets::MaterialMetadata::ValidationError,
           EditTickets::SubmissionExtras::ValidationError,
           EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue SecurityError
      render json: { ok: false, error: "Bad path" }, status: 400
    rescue => e
      Rails.logger.error("[create_annotation_system_submission] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { ok: false, error: "internal error" }, status: 500
    end

    def ticket_repo_root
      Rails.root.join("..").expand_path
    end

    def ticket_corpus_root
      configured = Rails.configuration.x.corpus_root
      return Pathname.new(configured).expand_path if configured.present?

      ticket_repo_root.join("corpus")
    end

    def split_corpus_front_matter(raw)
      result = CorpusSearch::DocumentReader.parse(raw.to_s)
      [result.metadata_entries.any? ? raw.to_s.lines.take(result.metadata_entries.length).join : "", result.body]
    end

    def normalize_ticket_text(text)
      value = text.to_s.dup.force_encoding("UTF-8").scrub
      value.end_with?("\n") ? value : (value + "\n")
    end

    def build_submission_text(nation:, work_title:, author:, page_title:, source_citation:, url:, body:)
      normalize_ticket_text(body)
    end

    def build_submission_metadata_json(target_dir_rel:, work_folder:, nation:, work_title:, author:, source_citation:, url:, date_label:, period:, polity:, region:, categories:, preview_rows:, text_type:)
      title = work_title.presence || work_folder
      payload = {
        "schema_version" => 1,
        "title" => title,
        "work_base_title" => title,
        "corpus_root" => nation.presence,
        "period" => period.presence,
        "polity" => polity.presence,
        "region" => region.presence,
        "date_label" => date_label.presence,
        "authors" => split_metadata_list(author),
        "categories" => Array(categories).presence || [],
        "sources" => [source_citation, url].map(&:presence).compact,
        "is_compilation" => false,
        "documents" => Array(preview_rows).map do |row|
          {
            "file" => File.basename(row.fetch("path")),
            "path" => row.fetch("path"),
            "page_title" => row["page_title"].presence
          }.compact
        end,
        "known_commentaries" => []
      }.compact

      JSON.pretty_generate(payload) + "
"
    end

    def update_metadata_payload_from_fields(payload, params)
      updated = payload.deep_dup
      updated["title"] = params[:metadata_title].to_s.strip
      updated["work_base_title"] = params[:metadata_title].to_s.strip if updated.key?("work_base_title")
      updated["authors"] = split_metadata_list(params[:metadata_authors])
      updated["date_label"] = params[:metadata_date_label].to_s.strip
      updated["corpus_root"] = params[:metadata_corpus_root].to_s.strip
      updated["period"] = params[:metadata_period].to_s.strip
      updated["polity"] = params[:metadata_polity].to_s.strip
      updated["region"] = params[:metadata_region].to_s.strip
      updated["categories"] = split_metadata_list(params[:metadata_categories])
      updated["sources"] = split_metadata_list(params[:metadata_sources])
      deep_blank_to_nil(updated).compact
    end

    def split_metadata_list(value)
      value.to_s.split(/[\n;；]+/).map(&:strip).reject(&:blank?).uniq
    end

    def deep_blank_to_nil(value)
      case value
      when Hash
        value.transform_values { |item| deep_blank_to_nil(item) }
      when Array
        value.map { |item| deep_blank_to_nil(item) }.reject { |item| item.respond_to?(:blank?) ? item.blank? : item.nil? }
      else
        value.respond_to?(:blank?) && value.blank? ? nil : value
      end
    end

    def clean_submission_directory?(relative_path)
      parts = relative_path.to_s.split("/").reject(&:blank?)
      parts.include?("clean")
    end

    def sanitize_submission_segment(value)
      cleaned = value.to_s.strip.delete("\/").sub(/\A\.+/, "").sub(/\.+\z/, "")
      cleaned.presence
    end

    def sanitize_submission_filename(value)
      cleaned = sanitize_submission_segment(value)
      return nil if cleaned.blank?
      cleaned += ".txt" unless cleaned.downcase.end_with?(".txt")
      cleaned
    end

    def permitted_text_type(value)
      allowed = %w[source kanbun hanmun hanvan]
      candidate = value.to_s.strip.downcase
      allowed.include?(candidate) ? candidate : nil
    end

    def permitted_annotation_system(value)
      candidate = value.to_s.strip.downcase
      %w[kanbun hanmun hanvan].include?(candidate) ? candidate : nil
    end

    def annotation_system_segment_in_path?(relative_path)
      relative_path.to_s.split("/").any? { |segment| %w[kanbun hanmun hanvan].include?(segment) }
    end

    def companion_segment_in_path?(relative_path)
      relative_path.to_s.split("/").any? { |segment| %w[kanbun hanmun hanvan translation].include?(segment) }
    end

    def companion_ticket_title(material_type, language_name)
      case material_type
      when "translation"
        "Translation#{language_name.present? ? " — #{language_name}" : ""}"
      when "gallery_image"
        "Image gallery submission"
      when "exemplar_manuscript"
        "Exemplar manuscript submission"
      when "variant_text"
        "Variant text connection"
      else
        "Companion material submission"
      end
    end

    def annotation_system_target_rel_path(base_path, annotation_system)
      dir = File.dirname(base_path.to_s)
      base = File.basename(base_path.to_s)
      [dir, annotation_system, base].reject(&:blank?).join("/")
    end

    def load_moderator_token_if_present
      # If a moderator token header is present and valid, store it.
      # This allows moderators to view tickets without needing the submitter key.
      scopes = %w[review_only apply_patch admin]
      @token_auth = EditTickets::ModeratorAuth.verify(request, scopes: scopes)
    end

    def load_ticket
      @ticket = EditTicket.find_by!(public_id: params[:public_id])
    end

    def require_submitter_key!
      return if @token_auth.present?

      key = request.get_header("HTTP_X_TICKET_KEY").to_s
      key = params[:ticket_key].to_s if key.blank?

      ok = EditTickets::KeyManager.valid?(@ticket.key_digest, key, @ticket.key_salt)
      return if ok

      render json: {
        ok: false,
        error: "invalid ticket key",
        hint: "If your submission is blocked by security limits, you can always open a GitHub Issue instead."
      }, status: 401
    end

    def require_moderator!
      needed_scopes = case action_name
      when "index"
        %w[review_only apply_patch admin]
      when "approve", "reject", "close"
        %w[apply_patch admin]
      else
        %w[review_only apply_patch admin]
      end

      auth = EditTickets::ModeratorAuth.verify(request, scopes: needed_scopes)
      @moderator = auth
      @token_auth ||= auth
      return if auth.present?

      render json: { ok: false, error: "moderator token required" }, status: 401
    end

    def ticket_json(ticket)
      {
        id: ticket.public_id,
        title: ticket.title,
        summary: ticket.summary,
        reasoning: ticket.reasoning,
        source: ticket.source,
        target_ref: ticket.target_ref,
        status: ticket.status,
        tags: ticket.tags,
        evidence_links: ticket.evidence_links,
        diff_metadata: ticket.diff_metadata,
        created_at: ticket.created_at,
        updated_at: ticket.updated_at,
        evidence_files: ticket.evidence_files.attachments.map { |att|
          {
            attachment_id: att.id,
            filename: att.blob.filename.to_s,
            content_type: att.blob.content_type,
            byte_size: att.blob.byte_size
          }
        },
        material_files: ticket.material_files.attachments.map { |att|
          {
            attachment_id: att.id,
            filename: att.blob.filename.to_s,
            content_type: att.blob.content_type,
            byte_size: att.blob.byte_size
          }
        },
        messages: ticket.ticket_messages.order(created_at: :asc).map { |m|
          {
            id: m.id,
            body: m.body,
            actor_type: m.actor_type,
            actor_label: m.actor_label,
            created_at: m.created_at
          }
        },
        audit: ticket.ticket_audit_events.order(created_at: :asc).map { |e|
          {
            id: e.id,
            action: e.action,
            actor_type: e.actor_type,
            actor_label: e.actor_label,
            metadata: e.metadata,
            created_at: e.created_at
          }
        }
      }
    end

    # Prevent path traversal and force the file to live under corpus_root.
    #
    # Pattern to reuse elsewhere:
    #   safe_join_under_root(root_dir, relative_path)
    # and then check File.file? / File.directory? on the result.
    def safe_join_under_root(root_dir, relative_path)
      root = Pathname.new(root_dir).expand_path
      rel = relative_path.to_s.sub(%r{\A/+}, "")
      abs = root.join(rel).cleanpath

      # If someone tries "../../etc/passwd", cleanpath will escape root; block it.
      raise SecurityError, "path escapes root" unless abs.to_s.start_with?(root.to_s + File::SEPARATOR) || abs == root

      abs.to_s
    end

    # Generate a unified diff using git (no-index) so we don't depend on a Ruby diff gem.
    #
    # Pattern to reuse elsewhere:
    #   stdout, status = Open3.capture2e("git", "diff", "--no-index", "--", a_path, b_path)
    # and then interpret exit status:
    #   0 => no diff
    #   1 => diff exists
    #   >1 => error
    def unified_diff_via_git(old_text, new_text, patch_path)
      require "open3"
      require "tempfile"

      Tempfile.create(["old", ".txt"]) do |a|
        Tempfile.create(["new", ".txt"]) do |b|
          a.binmode
          b.binmode
          a.write(old_text.to_s)
          b.write(new_text.to_s)
          a.flush
          b.flush

          # Some Git builds don't support `git diff --label` (the error you'll see is
          # "unknown option `label'"). We still want stable, corpus-relative names
          # in the diff header, so we generate a normal no-index diff and then rewrite
          # the header paths ourselves.
          args = [
            "git", "diff",
            "--no-index",
            "--unified=3",
            "--", a.path, b.path
          ]

          out, status = Open3.capture2e(*args)
          return "" if status.exitstatus == 0

          if status.exitstatus == 1
            a_label = "a/#{patch_path}"
            b_label = "b/#{patch_path}"

            # `git diff --no-index` outputs headers like:
            #   diff --git a/tmp/... b/tmp/...
            #   --- a/tmp/...
            #   +++ b/tmp/...
            # We replace those with:
            #   diff --git a/<patch_path> b/<patch_path>
            #   --- a/<patch_path>
            #   +++ b/<patch_path>
            return out.lines.map { |line|
              if line.start_with?("diff --git ")
                "diff --git #{a_label} #{b_label}\n"
              elsif line.start_with?("--- ")
                "--- #{a_label}\n"
              elsif line.start_with?("+++ ")
                "+++ #{b_label}\n"
              else
                line
              end
            }.join
          end

          raise "git diff failed (#{status.exitstatus}): #{out}"
        end
      end
    end
  end
end
