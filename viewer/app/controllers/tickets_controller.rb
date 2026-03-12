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
    @diff_text = load_diff_text
    @corpus_viewer_path = corpus_viewer_target_path
  end

  # In this workflow, approval means the change is accepted and applied.
  def approve
    require_scope!(%w[apply_patch admin])

    apply_ticket_changes!

    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "ticket_approved",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )

    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "ticket_applied",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )

    @ticket.update!(status: "applied")
    redirect_to ticket_path(@ticket.public_id), notice: "Approved and applied to local corpus file."
  rescue => e
    redirect_to ticket_path(@ticket.public_id), alert: "Approve/apply failed: #{e.message}"
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

  # Keep a separate manual apply button too.
  def apply_patch
    require_scope!(%w[apply_patch admin])

    apply_ticket_changes!

    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "ticket_applied",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { scope: @moderator.scope }
    )

    @ticket.update!(status: "applied")
    redirect_to ticket_path(@ticket.public_id), notice: "Applied to local corpus file."
  rescue => e
    redirect_to ticket_path(@ticket.public_id), alert: "Apply failed: #{e.message}"
  end

  def create_message
    require_scope!(%w[review_only apply_patch admin])

    body = params[:body].to_s
    raise ArgumentError, "message is empty" if body.strip.empty?

    msg = @ticket.ticket_messages.create!(
      body: body,
      actor_type: "moderator_token",
      actor_label: @moderator.name.presence || "moderator",
      created_at: Time.current
    )

    EditTickets::AuditLogger.log!(
      ticket: @ticket,
      action: "message_posted",
      actor_type: "moderator_token",
      actor_id: @moderator.id,
      actor_label: @moderator.name,
      metadata: { message_id: msg.id }
    )

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
    ref = @ticket.target_ref.to_s
    prefix = "#{@ticket.source}/"
    return nil unless ref.start_with?(prefix)

    path = ref.delete_prefix(prefix)
    path = path.sub(/#\d+\z/, "")
    path.presence
  end

  def load_diff_text
    diff_attachment = find_diff_attachment
    return nil unless diff_attachment

    raw = diff_attachment.blob.download
    raw.to_s.dup.force_encoding("UTF-8").scrub
  end

  def find_diff_attachment
    @ticket.evidence_files.attachments.find do |a|
      filename = a.blob.filename.to_s
      content_type = a.blob.content_type.to_s
      filename.end_with?(".diff") || content_type.include?("diff")
    end
  end

  def find_proposed_text_attachment
    @ticket.evidence_files.attachments.find do |a|
      filename = a.blob.filename.to_s
      filename.end_with?(".proposed.txt") || filename.include?(".proposed")
    end
  end

  def apply_ticket_changes!
    proposed = find_proposed_text_attachment
    if proposed
      write_proposed_text!(proposed.blob.download)
      return
    end

    if preserve_front_matter_for_ticket?
      raise "This ticket is missing its proposed text attachment, so applying the body-only diff would clobber metadata. Re-create the ticket after updating the server fix."
    end

    diff_attachment = find_diff_attachment
    raise "No diff attachment found." if diff_attachment.nil?
    apply_unified_diff!(diff_attachment.blob.download)
  end

  def write_proposed_text!(raw_text)
    rel = extract_corpus_relative_path!
    abs = safe_join_under_root(corpus_root, rel)
    FileUtils.mkdir_p(File.dirname(abs))

    proposed_body = normalize_ticket_text(raw_text)

    if preserve_front_matter_for_ticket?
      existing_text = File.exist?(abs) ? File.binread(abs).force_encoding("UTF-8").scrub : ""
      front_matter, _existing_body = split_corpus_front_matter(existing_text)

      if front_matter.present?
        normalized_front_matter = front_matter.rstrip
        normalized_body = proposed_body.sub(/\A\n+/, "")
        final_text = normalized_front_matter + "\n\n" + normalized_body
      else
        final_text = proposed_body
      end
    else
      final_text = proposed_body
    end

    File.open(abs, "wb:utf-8") { |f| f.write(final_text) }
  end

  def preserve_front_matter_for_ticket?
    @ticket.diff_metadata.is_a?(Hash) && @ticket.diff_metadata["preserve_front_matter"] == true
  end

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

  def extract_corpus_relative_path!
    files = Array(@ticket.diff_metadata && @ticket.diff_metadata["files"]).map(&:to_s)
    path = files.first.to_s
    raise "Ticket has no diff_metadata files list" if path.blank?
    raise "Diff touches disallowed paths" unless path.start_with?("corpus/")

    path.delete_prefix("corpus/")
  end

  def safe_join_under_root(root_dir, relative_path)
    root = Pathname.new(root_dir).expand_path
    rel = relative_path.to_s.sub(%r{\A/+}, "")
    abs = root.join(rel).cleanpath
    raise SecurityError, "path escapes root" unless abs.to_s.start_with?(root.to_s + File::SEPARATOR) || abs == root
    abs.to_s
  end

  def apply_unified_diff!(diff_text)
    allowed_roots = %w[corpus/ resources/ data/]
    files = Array(@ticket.diff_metadata && @ticket.diff_metadata["files"]).map(&:to_s)
    raise "Ticket has no diff_metadata files list" if files.empty?
    unless files.all? { |f| allowed_roots.any? { |root| f.start_with?(root) } }
      raise "Diff touches disallowed paths"
    end

    Tempfile.create(["ticket", ".diff"]) do |tf|
      tf.binmode
      tf.write(diff_text)
      tf.flush

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
