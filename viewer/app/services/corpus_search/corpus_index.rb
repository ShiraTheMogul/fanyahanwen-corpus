# frozen_string_literal: true

module CorpusSearch
  # Compact, rebuildable catalogue derived from the full manifest.
  #
  # This is deliberately generated during maintenance. Web requests only read
  # the prepared cache and never aggregate 494,000 manifest rows or traverse the
  # corpus filesystem.
  class CorpusIndex
    VERSION = 1
    CACHE_PATH = "corpus_index-v1.json.gz"
    FACET_FIELDS = %w[
      corpus_root
      macro_region
      polity
      period
      region
      document_role
    ].freeze

    attr_reader :generated_at, :manifest_generated_at, :document_count,
                :work_count, :facets, :folder_tree

    def self.load(cache_store: CacheStore.new)
      index = new(cache_store: cache_store)
      index.send(:load_from_payload, cache_store.read_json(CACHE_PATH))
      index
    end

    def self.build!(manifest:, cache_store: CacheStore.new)
      new(cache_store: cache_store).build!(manifest)
    end

    def initialize(cache_store: CacheStore.new)
      @cache_store = cache_store
      @generated_at = ""
      @manifest_generated_at = ""
      @document_count = 0
      @work_count = 0
      @facets = {}
      @folder_tree = FolderTree.load(cache_store: cache_store)
    end

    def build!(manifest)
      tree = FolderTree.load(manifest: manifest, cache_store: @cache_store)
      documents = Array(manifest.documents)
      searchable = documents.select do |document|
        role = document["document_role"].presence || DocumentRole.classify(document["path"])
        DocumentRole.searchable?(role)
      end

      payload = {
        "version" => VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "manifest_generated_at" => manifest.generated_at.to_s,
        "document_count" => searchable.length,
        "work_count" => searchable.filter_map { |document| document["work_id"].presence }.uniq.length,
        "facets" => build_facets(searchable),
        "folder_tree" => tree.roots
      }

      @cache_store.write_json(CACHE_PATH, payload)
      load_from_payload(payload)
      self
    end

    def empty?
      @folder_tree.empty?
    end

    private

    def build_facets(documents)
      FACET_FIELDS.to_h do |field|
        counts = Hash.new(0)
        documents.each do |document|
          value = document[field].to_s.strip
          next if value.empty?

          counts[value] += 1
        end
        [field, counts.sort_by { |value, count| [-count, value] }.to_h]
      end
    end

    def load_from_payload(payload)
      return self unless current_payload?(payload)

      @generated_at = payload["generated_at"].to_s
      @manifest_generated_at = payload["manifest_generated_at"].to_s
      @document_count = payload["document_count"].to_i
      @work_count = payload["work_count"].to_i
      @facets = payload["facets"].is_a?(Hash) ? payload["facets"] : {}
      @folder_tree = Struct.new(:roots) do
        def empty? = roots.empty?
      end.new(Array(payload["folder_tree"]))
      self
    end

    def current_payload?(payload)
      payload.is_a?(Hash) &&
        payload["version"].to_i == VERSION &&
        payload["folder_tree"].is_a?(Array) &&
        payload["facets"].is_a?(Hash)
    end
  end
end
