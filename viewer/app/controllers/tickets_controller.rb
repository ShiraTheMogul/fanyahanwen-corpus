class TicketsController < ApplicationController
  helper GrammarHelper
  helper AtlasHelper
  before_action :require_moderator!
  before_action :load_ticket, only: %i[show approve reject close apply_patch create_message]

  def index
    status = params[:status].presence
    tag = params[:tag].presence

    scope = EditTicket.all.order(created_at: :desc)
    scope = scope.where(status: status) if status
    tickets = scope.limit(200)
    tickets = tickets.select { |ticket| Array(ticket.tags).map(&:to_s).include?(tag) } if tag.present?

    @tickets = tickets.first(200)
    @status = status
    @tag = tag
  end

  def show
    @messages = @ticket.ticket_messages.order(created_at: :asc)
    @audit = @ticket.ticket_audit_events.order(created_at: :asc)
    @attachments = @ticket.evidence_files.attachments
    @material_attachments = @ticket.material_files.attachments
    @diff_text = load_diff_text
    load_grammar_proposal
    load_atlas_proposal
    @corpus_viewer_path = corpus_viewer_target_path
    @contact = active_contact
  end

  # Approval is deliberately one operation here: accept the proposal and apply it.
  # The JSON moderator endpoint uses the same TicketApplier service.
  def approve
    require_scope!(%w[apply_patch admin])
    apply_ticket_changes!

    log_moderator_action!("ticket_approved")
    log_moderator_action!("ticket_applied")
    @ticket.update!(status: "applied")

    redirect_to ticket_path(@ticket.public_id), notice: "Approved and applied to local corpus file."
  rescue => e
    redirect_to ticket_path(@ticket.public_id), alert: "Approve/apply failed: #{e.message}"
  end

  def reject
    require_scope!(%w[apply_patch admin])
    reason = params[:reason].to_s
    @ticket.update!(status: "rejected")
    log_moderator_action!("ticket_rejected", reason: reason)
    redirect_to ticket_path(@ticket.public_id), notice: "Rejected."
  end

  def close
    require_scope!(%w[apply_patch admin])
    @ticket.close!
    log_moderator_action!("ticket_closed")
    @ticket.ticket_contact&.destroy!
    redirect_to ticket_path(@ticket.public_id), notice: "Closed."
  end

  def apply_patch
    require_scope!(%w[apply_patch admin])
    apply_ticket_changes!
    log_moderator_action!("ticket_applied")
    @ticket.update!(status: "applied")
    redirect_to ticket_path(@ticket.public_id), notice: "Applied to local corpus file."
  rescue => e
    redirect_to ticket_path(@ticket.public_id), alert: "Apply failed: #{e.message}"
  end

  def create_message
    require_scope!(%w[review_only apply_patch admin])

    body = params[:body].to_s
    raise ArgumentError, "message is empty" if body.strip.empty?

    message = @ticket.ticket_messages.create!(
      body: body,
      actor_type: "moderator_token",
      actor_label: @moderator.name.presence || "moderator",
      created_at: Time.current
    )

    log_moderator_action!("message_posted", message_id: message.id)
    redirect_to ticket_path(@ticket.public_id), notice: "Message posted."
  rescue ArgumentError => e
    redirect_to ticket_path(@ticket.public_id), alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    redirect_to ticket_path(@ticket.public_id), alert: e.record.errors.full_messages.join(", ")
  end

  private

  def load_ticket
    @ticket = EditTicket.find_by!(public_id: params[:public_id])
  end

  def require_moderator!
    token = session[:moderator_token].to_s
    @moderator = EditTickets::ModeratorAuth.verify_plaintext(token, scopes: %w[review_only apply_patch admin])
    return if @moderator.present?

    redirect_to tickets_login_path
  end

  def require_scope!(allowed)
    return if allowed.map(&:to_s).include?(@moderator.scope.to_s)

    raise ActionController::RoutingError, "forbidden"
  end

  def repo_root
    Rails.root.join("..").expand_path
  end

  def corpus_root
    configured = Rails.configuration.x.corpus_root
    return Pathname.new(configured).expand_path if configured.present?

    repo_root.join("corpus")
  end

  def corpus_viewer_target_path
    metadata = @ticket.diff_metadata.is_a?(Hash) ? @ticket.diff_metadata : {}
    return metadata["target_path"].presence if metadata["target_path"].present?

    reference = @ticket.target_ref.to_s
    prefix = "#{@ticket.source}/"
    return nil unless reference.start_with?(prefix)

    reference.delete_prefix(prefix).sub(/#.*\z/, "").presence
  end

  def load_diff_text
    attachment = @ticket.evidence_files.attachments.find do |candidate|
      filename = candidate.blob.filename.to_s
      content_type = candidate.blob.content_type.to_s
      filename.end_with?(".diff") || content_type.include?("diff")
    end
    return nil unless attachment

    attachment.blob.download.to_s.dup.force_encoding("UTF-8").scrub
  end

  def load_grammar_proposal
    metadata = @ticket.diff_metadata.is_a?(Hash) ? @ticket.diff_metadata : {}
    return unless metadata["kind"] == "grammar_entry_submission"

    attachment = @ticket.evidence_files.attachments.find do |candidate|
      candidate.blob.filename.to_s.include?(".proposed")
    end
    return unless attachment

    raw = attachment.blob.download.to_s.dup.force_encoding("UTF-8").scrub
    @grammar_proposed_document = Grammar::MarkdownDocument.parse(raw)
    @grammar_entry = Grammar::EntryStore.default.find(metadata["entry_id"])
  rescue Psych::SyntaxError, ArgumentError => e
    @grammar_proposed_error = e.message
  end

  def load_atlas_proposal
    metadata = @ticket.diff_metadata.is_a?(Hash) ? @ticket.diff_metadata : {}
    return unless metadata["kind"] == "atlas_article_submission"

    attachment = @ticket.evidence_files.attachments.find do |candidate|
      candidate.blob.filename.to_s.include?(".proposed")
    end
    return unless attachment

    raw = attachment.blob.download.to_s.dup.force_encoding("UTF-8").scrub
    @atlas_proposed_document = Grammar::MarkdownDocument.parse(raw)
    @atlas_entry = Atlas::EntryStore.default.find(metadata["entry_id"])
  rescue Psych::SyntaxError, ArgumentError => e
    @atlas_proposed_error = e.message
  end

  def active_contact
    contact = @ticket.ticket_contact
    return nil if contact.nil?

    if contact.expired?
      contact.destroy!
      nil
    else
      contact
    end
  end

  def apply_ticket_changes!
    EditTickets::TicketApplier.new(
      ticket: @ticket,
      repo_root: repo_root,
      corpus_root: corpus_root,
      annotation_items: params[:annotation_items],
      reviewer_name: @moderator.name
    ).call
  end

  def log_moderator_action!(action, metadata = {})
    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: action,
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }.merge(metadata)
    )
  end
end
