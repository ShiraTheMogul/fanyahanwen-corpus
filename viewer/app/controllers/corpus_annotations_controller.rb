# frozen_string_literal: true

class CorpusAnnotationsController < ApplicationController
  protect_from_forgery with: :exception

  def show
    if params[:auto].to_s == "1"
      render json: automatic_historical_annotation_payload
      return
    end

    store = store_for_request
    data = store.read
    render json: data
  rescue SecurityError
    render json: { error: "Bad path" }, status: :bad_request
  rescue Errno::ENOENT
    if params[:auto].to_s == "1"
      render json: { version: 1, items: [], context: {}, authority: {}, cached: false }
    else
      render json: { version: 1, items: [], updated_at: nil }
    end
  rescue StandardError => e
    raise unless params[:auto].to_s == "1"

    Rails.logger.warn("[authority] automatic annotation request failed: #{e.class}: #{e.message}")
    render json: { error: "Historical annotations are temporarily unavailable." }, status: :unprocessable_entity
  end

  # POST /corpus_annotations
  #
  # Public path: create a ticket for an annotation edit.
  # This does not write the annotation file directly.
  def update
    target_path = params[:path].to_s
    if target_path.blank?
      render json: { ok: false, error: "path is required" }, status: :unprocessable_entity
      return
    end

    payload = annotation_payload_from_params
    source_path = params[:source_path].to_s.strip.sub(%r{\A/+}, "").presence || target_path
    validate_source_path!(source_path)

    store = store_for_request
    existing = read_existing_annotations(store)
    proposed = { "version" => 1, "items" => payload["items"] }

    diff_text = unified_diff_for_annotations(existing, proposed, target_path)
    if diff_text.blank?
      render json: { ok: false, error: "No annotation changes detected" }, status: :unprocessable_entity
      return
    end

    metadata = EditTickets::UnifiedDiffValidator.validate!(
      diff_text,
      allowed_roots: ["corpus/"]
    ).merge(
      "kind" => "annotations_edit",
      "target_path" => target_path,
      "source_path" => source_path,
      "annotation_path" => "#{target_path}.annotations.json",
      "preview_items" => preview_items_from_params,
      "proposed_annotations" => proposed
    )

    ticket_key = EditTickets::KeyManager.generate_plaintext
    salt = EditTickets::KeyManager.generate_salt
    digest = EditTickets::KeyManager.digest(ticket_key, salt)

    source = params[:source].to_s.presence || "corpus_viewer"
    material_metadata = EditTickets::MaterialMetadata.build!(params)
    links = EditTickets::SubmissionExtras.evidence_links(params[:evidence_links])
    uploads = EditTickets::SubmissionExtras.validate_uploads!(params[:evidence_files])
    metadata = metadata.merge(material_metadata)
    ticket = EditTicket.new(
      public_id: SecureRandom.hex(12),
      title: params[:title].to_s.presence || "Annotation edit",
      summary: params[:summary].to_s,
      reasoning: params[:reasoning].to_s,
      source: source,
      target_ref: "#{source}/#{target_path}#annotations",
      status: "open",
      evidence_links: links,
      key_salt: salt,
      key_digest: digest,
      key_generated_at: Time.current,
      diff_metadata: metadata
    )

    ticket.tags = EditTickets::Tagger.tags_for(
      source: ticket.source,
      target_ref: ticket.target_ref,
      has_diff: true,
      has_uploads: true,
      link_count: links.size,
      material_type: "annotations"
    )

    ticket.transaction do
      ticket.save!
      proposed_json = JSON.pretty_generate(proposed) + "\n"
      ticket.evidence_files.attach([
        {
          io: StringIO.new(diff_text),
          filename: "annotations_#{File.basename(target_path)}.diff",
          content_type: "text/plain"
        },
        {
          io: StringIO.new(proposed_json),
          filename: "annotations_#{File.basename(target_path)}.proposed.txt",
          content_type: "text/plain"
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
          kind: "annotations_edit"
        }
      )
    end

    render json: {
      ok: true,
      ticket_id: ticket.public_id,
      ticket: {
        id: ticket.public_id,
        status: ticket.status,
        tags: ticket.tags
      },
      ticket_key: ticket_key,
      warning: "This key is shown once. Save it now (copy it, download a txt, or explicitly store it on this device)."
    }, status: :created
  rescue ActionController::ParameterMissing
    render json: { ok: false, error: "Missing annotations payload" }, status: :unprocessable_entity
  rescue JSON::ParserError
    render json: { ok: false, error: "Invalid annotations payload" }, status: :unprocessable_entity
  rescue EditTickets::MaterialMetadata::ValidationError,
         EditTickets::SubmissionExtras::ValidationError,
         EditTickets::UnifiedDiffValidator::ValidationError => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { ok: false, error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  rescue SecurityError
    render json: { ok: false, error: "Bad path" }, status: :bad_request
  end

  private

  # The automatic reader annotations are deliberately handled by the controller
  # that owns GET /corpus_annotations. Earlier versions also prepended a concern
  # over this action and kept a second, incompatible response implementation in
  # the controller. That made the actual endpoint depend on Rails ancestor order.
  def automatic_historical_annotation_payload
    target_path = normalized_corpus_path(params[:path])
    source_path = normalized_corpus_path(params[:source_path]).presence || target_path
    raise SecurityError, "target path is missing" if target_path.blank?

    fs = CorpusFs.new(root: corpus_root)
    target_absolute = fs.resolve(target_path)
    source_absolute = fs.resolve(source_path)
    raise SecurityError, "target is not a corpus file" unless fs.file?(target_absolute)
    raise SecurityError, "source is not a corpus work/file" unless fs.file?(source_absolute) || fs.directory?(source_absolute)

    metadata_store = CorpusMetadataStore.new(root: corpus_root, fs: fs)
    detailed_metadata = metadata_store.document_metadata_for_path(source_path)
    search_metadata = metadata_store.search_metadata_for_path(source_path)
    metadata = detailed_metadata.merge(search_metadata) do |_key, detailed, search_value|
      detailed.to_s.strip.empty? ? search_value : detailed
    end

    body = automatic_historical_annotation_text(
      fs: fs,
      metadata_store: metadata_store,
      target_absolute: target_absolute,
      source_path: source_path,
      source_absolute: source_absolute
    )

    result = HistoricalAutoAnnotationCache.fetch(
      text: body,
      metadata: metadata,
      cache_identity: "#{source_path}\0#{target_path}",
      store: HistoricalAuthorityStore.default
    )

    {
      version: 1,
      items: result.items,
      context: result.context,
      authority: result.authority,
      cached: result.cached
    }
  end

  def automatic_historical_annotation_text(fs:, metadata_store:, target_absolute:, source_path:, source_absolute:)
    unless fs.directory?(source_absolute)
      return CorpusSearch::DocumentReader.parse(fs.read_text(target_absolute)).body.to_s
    end

    metadata_store.document_paths_for_work_folder(source_path).filter_map do |document_path|
      document_absolute = fs.resolve(document_path)
      next unless fs.file?(document_absolute)

      CorpusSearch::DocumentReader.parse(fs.read_text(document_absolute)).body.to_s.presence
    rescue Errno::ENOENT, SecurityError
      nil
    end.join("\n\n")
  end

  def normalized_corpus_path(value)
    value.to_s.tr("\\", "/").sub(%r{\A/+}, "")
  end

  def annotation_payload_from_params
    raw = params.require(:annotations)
    raw = JSON.parse(raw) if raw.is_a?(String)
    raw = ActionController::Parameters.new(raw) unless raw.respond_to?(:permit)
    payload = raw.permit(:version, items: [:start, :end, :kind, :note]).to_h

    items = Array(payload["items"]).map do |item|
      start_idx = item["start"].to_i
      end_idx = item["end"].to_i
      next if end_idx <= start_idx

      normalized = {
        "start" => start_idx,
        "end" => end_idx,
        "kind" => item["kind"].to_s,
        "note" => item["note"].to_s.presence
      }.compact
      next unless CorpusAnnotationsStore::KINDS.include?(normalized["kind"])

      if normalized["kind"] == "ambiguous_character" && normalized["note"].blank?
        raise EditTickets::MaterialMetadata::ValidationError, "Ambiguous/disputed character annotations require a note"
      end

      normalized
    end.compact

    { "version" => 1, "items" => items }
  end

  def preview_items_from_params
    raw = params[:preview_items]
    return [] if raw.blank?

    raw = JSON.parse(raw) if raw.is_a?(String)
    Array(raw).map do |item|
      {
        "start" => item["start"].to_i,
        "end" => item["end"].to_i,
        "kind" => item["kind"].to_s,
        "note" => item["note"].to_s.presence,
        "text" => item["text"].to_s
      }.compact
    end
  rescue JSON::ParserError
    []
  end

  def read_existing_annotations(store)
    data = store.read
    {
      "version" => data["version"].to_i.positive? ? data["version"].to_i : 1,
      "items" => Array(data["items"])
    }
  rescue Errno::ENOENT
    { "version" => 1, "items" => [] }
  end

  def unified_diff_for_annotations(existing, proposed, target_path)
    current_json = JSON.pretty_generate(existing) + "\n"
    proposed_json = JSON.pretty_generate(proposed) + "\n"
    patch_path = "corpus/#{target_path}.annotations.json"

    unified_diff_via_git(current_json, proposed_json, patch_path)
  end

  def store_for_request
    root = corpus_root
    rel_path = params[:path].to_s
    CorpusAnnotationsStore.new(root: root, rel_text_path: rel_path)
  end

  def validate_source_path!(source_path)
    fs = CorpusFs.new(root: corpus_root)
    absolute = fs.resolve(source_path)
    raise SecurityError, "source path is not a corpus file" unless fs.file?(absolute)
  end

  def corpus_root
    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    root
  end

  def unified_diff_via_git(old_text, new_text, patch_path)
    require "open3"
    require "tempfile"

    Tempfile.create(["old_annotations", ".json"]) do |a|
      Tempfile.create(["new_annotations", ".json"]) do |b|
        a.binmode
        b.binmode
        a.write(old_text.to_s)
        b.write(new_text.to_s)
        a.flush
        b.flush

        out, status = Open3.capture2e(
          "git", "diff", "--no-index", "--unified=3", "--", a.path, b.path
        )
        return "" if status.exitstatus == 0

        if status.exitstatus == 1
          a_label = "a/#{patch_path}"
          b_label = "b/#{patch_path}"

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
