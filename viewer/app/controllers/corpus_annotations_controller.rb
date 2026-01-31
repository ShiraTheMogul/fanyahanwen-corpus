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

    render json: { ok: true }
  rescue ActionController::ParameterMissing
    render json: { error: "Missing annotations payload" }, status: :unprocessable_entity
  rescue SecurityError
    render json: { error: "Bad path" }, status: :bad_request
  end

  private

  def store_for_request
    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    rel_path = params[:path].to_s
    CorpusAnnotationsStore.new(root: root, rel_text_path: rel_path)
  end
end
