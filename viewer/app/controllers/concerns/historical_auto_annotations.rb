# frozen_string_literal: true

# Extends the existing GET /corpus_annotations endpoint with ?auto=1 while
# leaving the manual .annotations.json workflow untouched.
module HistoricalAutoAnnotations
  def show
    return super unless params[:auto].to_s == "1"

    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    target_path = params[:path].to_s.tr("\\", "/").sub(%r{\A/+}, "")
    source_path = params[:source_path].to_s.tr("\\", "/").sub(%r{\A/+}, "").presence || target_path
    fs = CorpusFs.new(root: root)
    target_absolute = fs.resolve(target_path)
    source_absolute = fs.resolve(source_path)
    raise SecurityError, "target is not a corpus file" unless fs.file?(target_absolute)
    raise SecurityError, "source is not a corpus work/file" unless fs.file?(source_absolute) || fs.directory?(source_absolute)

    metadata_store = CorpusMetadataStore.new(root: root, fs: fs)
    metadata = metadata_store.document_metadata_for_path(source_path)
    search_metadata = metadata_store.search_metadata_for_path(source_path)
    merged_metadata = metadata.merge(search_metadata) do |_key, detailed, search_value|
      detailed.to_s.strip.empty? ? search_value : detailed
    end

    raw = fs.read_text(target_absolute)
    body = CorpusSearch::DocumentReader.parse(raw).body.to_s
    result = CbdbAutoAnnotator.call(
      text: body,
      metadata: merged_metadata,
      store: HistoricalAuthorityStore.default
    )

    render json: {
      version: 1,
      items: result.items,
      context: result.context,
      authority: result.authority
    }
  rescue SecurityError
    render json: { error: "Bad path" }, status: :bad_request
  rescue Errno::ENOENT
    render json: { version: 1, items: [], context: {}, authority: {} }
  end
end
