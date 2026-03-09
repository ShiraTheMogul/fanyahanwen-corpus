module Api
  class EditTicketsController < ApplicationController
    protect_from_forgery with: :null_session

    before_action :load_ticket, only: %i[show create_message approve reject close download_evidence]
    before_action :load_moderator_token_if_present, only: %i[show index create_message download_evidence]
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
  end
end
