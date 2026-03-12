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
      ticket_key = EditTickets::KeyManager.generate_plaintext
      salt = EditTickets::KeyManager.generate_salt
      digest = EditTickets::KeyManager.digest(ticket_key, salt)

      links = params[:evidence_links]
      links = JSON.parse(links) if links.is_a?(String)
      links = Array(links).map(&:to_s).map(&:strip).reject(&:blank?)

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

      # Optional diff upload (unified diff). We store the file as evidence, but validate
      # and record metadata so reviewers can see what it touches.
      diff_file = params[:diff_file]
      if diff_file.present?
        EditTickets::EvidenceValidator.validate!(diff_file)

        diff_text = diff_file.tempfile.read
        diff_file.tempfile.rewind

        metadata = EditTickets::UnifiedDiffValidator.validate!(
          diff_text,
          allowed_roots: ["corpus/", "resources/", "data/"]
        )
        ticket.diff_metadata = metadata
        ticket.evidence_files.attach(diff_file)
      end

      # Optional evidence uploads.
      uploads = Array(params[:evidence_files])
      uploads.each do |uploaded|
        EditTickets::EvidenceValidator.validate!(uploaded)
        ticket.evidence_files.attach(uploaded)
      end

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: ticket.diff_metadata.present? && ticket.diff_metadata["file_count"].to_i.positive?,
        has_uploads: ticket.evidence_files.attached?,
        link_count: ticket.evidence_links.size
      )

      ticket.save!

      # Optional contact info (encrypted, expires after 30 days).
      if params[:contact].present?
        contact_hash = params[:contact]
        contact_hash = JSON.parse(contact_hash) if contact_hash.is_a?(String)
        contact_hash ||= {}

        if contact_hash["email"].present? || contact_hash["name"].present? || contact_hash["notes"].present?
          TicketContact.create!(
            edit_ticket: ticket,
            name: contact_hash["name"].to_s,
            email: contact_hash["email"].to_s,
            notes: contact_hash["notes"].to_s,
            expires_at: 30.days.from_now
          )
        end
      end

      EditTickets::AuditLogger.log!(
        ticket: ticket,
        action: "ticket_created",
        actor_type: "submitter",
        metadata: { source: ticket.source, target_ref: ticket.target_ref, tags: ticket.tags }
      )

      render json: {
        ok: true,
        # Back-compat: some client UIs expect a top-level `ticket_id`.
        ticket_id: ticket.public_id,
        ticket: {
          id: ticket.public_id,
          status: ticket.status,
          tags: ticket.tags
        },
        ticket_key: ticket_key,
        warning: "This key is shown once. Save it now (copy it, download a txt, or store it on this device in the UI)."
      }, status: 201
    rescue EditTickets::EvidenceValidator::ValidationError, EditTickets::UnifiedDiffValidator::ValidationError => e
      render json: { ok: false, error: e.message }, status: 422
    rescue ActiveRecord::RecordInvalid => e
      render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: 422
    rescue JSON::ParserError
      render json: { ok: false, error: "invalid JSON in evidence_links/contact" }, status: 422
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

      return render(json: { ok: false, error: "target_path is required" }, status: 422) if target_path.blank?
      return render(json: { ok: false, error: "new_text is required" }, status: 422) if new_text.blank?

      corpus_root = Rails.configuration.x.corpus_root
      corpus_root = Rails.root.join("..", "corpus") if corpus_root.to_s.strip.empty?

      fs_path = safe_join_under_root(corpus_root, target_path)
      return render(json: { ok: false, error: "Not a file" }, status: 422) unless File.file?(fs_path)

      old_text = File.binread(fs_path).force_encoding("UTF-8").scrub
      _front_matter, old_body = split_corpus_front_matter(old_text)
      normalized_new_text = normalize_ticket_text(new_text)
      normalized_old_body = normalize_ticket_text(old_body)

      # IMPORTANT: corpus-viewer text edits only edit the body, not the leading metadata block.
      # We therefore diff body-to-body for display/review, and preserve the existing metadata when applying.
      patch_path = "corpus/#{target_path}"

      diff_text = unified_diff_via_git(normalized_old_body, normalized_new_text, patch_path)
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
        title: params[:title].to_s.presence || "Text edit",
        summary: params[:summary].to_s,
        reasoning: params[:reasoning].to_s,
        source: source,
        target_ref: "#{source}/#{target_path}#1",
        status: "open",
        evidence_links: [],
        key_salt: salt,
        key_digest: digest,
        key_generated_at: Time.current,
        diff_metadata: metadata.merge(
          "edit_mode" => "body_only",
          "target_path" => target_path,
          "preserve_front_matter" => true
        )
      )

      ticket.tags = EditTickets::Tagger.tags_for(
        source: ticket.source,
        target_ref: ticket.target_ref,
        has_diff: true,
        has_uploads: true,
        link_count: 0
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
        warning: "This key is shown once. Save it now (copy it, download a txt, or store it on this device in the UI)."
      }, status: 201
    rescue EditTickets::UnifiedDiffValidator::ValidationError => e
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
      @ticket.update!(status: "approved")
      EditTickets::AuditLogger.log!(
        ticket: @ticket,
        action: "ticket_approved",
        actor_type: "moderator_token",
        actor_id: @moderator.id,
        actor_label: @moderator.name,
        metadata: { scope: @moderator.scope }
      )
      render json: { ok: true }
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
      attachment = @ticket.evidence_files.attachments.find(params[:attachment_id])
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


    def split_corpus_front_matter(raw)
      lines = raw.to_s.lines
      meta = []
      i = 0

      while i < lines.length && lines[i].start_with?("#")
        meta << lines[i]
        i += 1
      end

      [meta.join, lines[i..].join]
    end

    def normalize_ticket_text(text)
      value = text.to_s.dup.force_encoding("UTF-8").scrub
      value.end_with?("\n") ? value : (value + "\n")
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
        evidence_files: ticket.evidence_files.attachments.map { |att|
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
