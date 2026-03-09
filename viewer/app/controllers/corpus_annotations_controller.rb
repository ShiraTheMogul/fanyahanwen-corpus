# frozen_string_literal: true

# Stores and serves user-contributed corpus annotations (names, placenames, titles, etc.)
#
# Storage model:
# - For a corpus text file "path/to/foo.txt"
# - The annotation file lives next to it as "path/to/foo.txt.annotations.json"
#
# JSON shape (versioned):
# {
#   "version": 1,
#   "items": [
#     {"start": 10, "end": 14, "kind": "person", "note": "optional"}
#   ],
#   "updated_at": "2026-01-31T00:00:00Z"
# }
#
# IMPORTANT: This controller assumes the server process has write access to the corpus root.
class CorpusAnnotationsController < ApplicationController
  protect_from_forgery with: :exception

  before_action :require_ticket!, only: [:update]

  def show
    store = store_for_request
    data = store.read
    render json: data
  rescue SecurityError
    render json: { error: "Bad path" }, status: :bad_request
  rescue Errno::ENOENT
    # No annotations yet is not an error.
    render json: { version: 1, items: [], updated_at: nil }
  end

  def update
    store = store_for_request

    payload = params.require(:annotations).permit(:version, items: [:start, :end, :kind, :note]).to_h

    # Basic validation / normalization
    version = payload["version"].to_i
    items = Array(payload["items"]).map do |it|
      {
        "start" => it["start"].to_i,
        "end"   => it["end"].to_i,
        "kind"  => it["kind"].to_s,
        "note"  => it["note"].to_s.presence
      }.compact
    end

    store.write({ "version" => (version <= 0 ? 1 : version), "items" => items })

    # Record an audit entry on the ticket so moderation can see what happened.
    @ticket.ticket_audit_events.create!(
      action: "annotations_updated",
      actor_type: (@moderator_token.present? ? "moderator" : "submitter"),
      actor_label: (@moderator_token&.label),
      metadata: { path: params[:path].to_s, item_count: items.length },
    )

    render json: { ok: true, ticket_id: @ticket.public_id }
  rescue ActionController::ParameterMissing
    render json: { error: "Missing annotations payload" }, status: :unprocessable_entity
  rescue SecurityError
    render json: { error: "Bad path" }, status: :bad_request
  end

  private

  def require_ticket!
    ticket_id = params[:ticket_id].to_s.presence || request.get_header("HTTP_X_TICKET_ID").to_s.presence
    if ticket_id.blank?
      render json: { ok: false, error: "ticket_id is required" }, status: :unprocessable_entity
      return
    end

    @ticket = EditTicket.find_by(public_id: ticket_id)
    if @ticket.nil?
      render json: { ok: false, error: "ticket not found" }, status: :not_found
      return
    end

    # Allow maintainers to authenticate with a moderator token.
    @moderator_token = EditTickets::ModeratorAuth.verify(request, scopes: %w[admin apply_patch review_only])

    unless @moderator_token.present?
      ticket_key = params[:ticket_key].to_s.presence || request.get_header("HTTP_X_TICKET_KEY").to_s.presence
      unless EditTickets::KeyManager.new(@ticket).verify_submitter_key(ticket_key)
        render json: { ok: false, error: "invalid ticket_key" }, status: :unauthorized
        return
      end
    end

    if @ticket.status.to_s != "open"
      render json: { ok: false, error: "ticket is not open" }, status: :conflict
      return
    end
  end

  def store_for_request
    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    rel_path = params[:path].to_s
    CorpusAnnotationsStore.new(root: root, rel_text_path: rel_path)
  end
end
