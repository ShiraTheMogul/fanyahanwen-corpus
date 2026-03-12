require "shellwords"

class TicketsController < ApplicationController
  before_action :require_moderator!
  before_action :load_ticket, only: %i[show approve reject close apply_patch create_message]

  def index
    status = params[:status].presence
    tag = params[:tag].presence

    scope = EditTicket.all.order(created_at: :desc)
    scope = scope.where(status: status) if status
    tickets = scope.limit(200)

    if tag.present?
      tickets = tickets.select { |t| Array(t.tags).map(&:to_s).include?(tag) }
    end

    @tickets = tickets.first(200)
    @status = status
    @tag = tag
  end

  def show
    @messages = @ticket.ticket_messages.order(created_at: :asc)
    @audit = @ticket.ticket_audit_events.order(created_at: :asc)
    @attachments = @ticket.evidence_files.attachments

    @diff_text = nil
    diff_attachment = @attachments.find { |a| a.blob.content_type.to_s.include?("diff") || a.blob.filename.to_s.end_with?(".diff") }
    if diff_attachment
      # ActiveStorage returns a binary (ASCII-8BIT) string. That can explode when
      # we later HTML-escape it in the view (UTF-8 vs BINARY mismatch).
      # For display only, force UTF-8 and scrub invalid bytes.
      raw = diff_attachment.blob.download
      @diff_text = raw.to_s.dup.force_encoding("UTF-8").scrub
    end
  end


  def create_message
    body = params[:body].to_s
    if body.strip.empty?
      redirect_to ticket_path(@ticket.public_id), alert: "Message cannot be empty."
      return
    end

    @ticket.ticket_messages.create!(
      body: body,
      actor_type: "moderator_token",
      actor_label: @moderator.name,
      created_at: Time.current
    )

    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "message_posted",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )

    redirect_to ticket_path(@ticket.public_id), notice: "Message posted."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to ticket_path(@ticket.public_id), alert: e.record.errors.full_messages.join(", ")
  end

  def approve
    require_scope!(%w[apply_patch admin])
    @ticket.update!(status: "approved")
    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "ticket_approved",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )
    redirect_to ticket_path(@ticket.public_id), notice: "Approved."
  end

  def reject
    require_scope!(%w[apply_patch admin])
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
    redirect_to ticket_path(@ticket.public_id), notice: "Rejected."
  end

  def close
    require_scope!(%w[apply_patch admin])
    @ticket.close!
    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "ticket_closed",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )
    @ticket.ticket_contact&.destroy!
    redirect_to ticket_path(@ticket.public_id), notice: "Closed."
  end

  # Apply the diff evidence (git-apply) into the monorepo working tree.
  # This is intended for local maintainer usage.
  def apply_patch
    require_scope!(%w[apply_patch admin])

    diff_attachment = @ticket.evidence_files.attachments.find { |a| a.blob.filename.to_s.end_with?(".diff") || a.blob.content_type.to_s.include?("diff") }
    return redirect_to(ticket_path(@ticket.public_id), alert: "No diff attachment found.") if diff_attachment.nil?

    diff_text = diff_attachment.blob.download
    apply_unified_diff!(diff_text)

    @ticket.update!(status: "applied")
    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "ticket_applied",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )

    redirect_to ticket_path(@ticket.public_id), notice: "Patch applied to working tree."
  rescue => e
    redirect_to ticket_path(@ticket.public_id), alert: "Apply failed: #{e.message}"
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
    # Monorepo layout: fanyahanwen-corpus/
    #   viewer/   (Rails.root)
    #   corpus/   (large data)
    Rails.root.join("..").expand_path
  end

  def apply_unified_diff!(diff_text)
    # Safety: only allow diffs that touch whitelisted roots.
    allowed_roots = %w[corpus/ resources/ data/]
    files = Array(@ticket.diff_metadata && @ticket.diff_metadata["files"]).map(&:to_s)
    if files.empty?
      raise "Ticket has no diff_metadata files list"
    end
    unless files.all? { |f| allowed_roots.any? { |root| f.start_with?(root) } }
      raise "Diff touches disallowed paths"
    end

    Tempfile.create(["ticket", ".diff"]) do |tf|
      tf.write(diff_text)
      tf.flush

      # -p1 strips the leading "a/" or "b/" from the diff paths.
      cmd = ["git", "apply", "--whitespace=nowarn", "-p1", tf.path]
      out = nil
      status = nil
      Dir.chdir(repo_root) do
        out = `#{cmd.map { |c| Shellwords.escape(c) }.join(" ")} 2>&1`
        status = $?.exitstatus
      end

      raise "git apply failed (#{status}): #{out}" unless status == 0
    end
  end
end
