# frozen_string_literal: true

module CorpusSearch
  # A small, cached browse tree for the search form.
  #
  # The corpus may contain hundreds of thousands of work-level folders, so the
  # form deliberately exposes the stable, useful upper levels rather than
  # rendering the entire filesystem. Selecting any shown folder still includes
  # every descendant beneath that exact corpus-relative path.
  class FolderTree
    CACHE_VERSION = 1
    CACHE_PATH = "folder_tree-v1.json.gz"
    MAX_DEPTH = 3

    PREFERRED_ROOT_ORDER = %w[
      中國漢文
      四庫全書
      朝鮮漢文
      日本漢文
      琉球漢文
      越南漢文
      新加坡漢文
      馬來西亞漢文
      菲律賓漢文
      他漢文
    ].freeze

    LAYER_ORDER = {
      "clean" => 0,
      "raw" => 1
    }.freeze

    attr_reader :roots, :manifest_generated_at

    def self.load(manifest: nil, cache_store: CacheStore.new)
      if manifest.nil?
        cached = cache_store.read_json(CACHE_PATH)
        if cached_payload_current?(cached) && cache_file_fresh?(cache_store)
          tree = new(manifest: nil, cache_store: cache_store)
          tree.send(:load_from_payload, cached)
          return tree
        end

        manifest = Manifest.load(cache_store: cache_store)
      end

      new(manifest: manifest, cache_store: cache_store).load_cached_or_build!
    end

    def self.cached_payload_current?(payload)
      payload.is_a?(Hash) &&
        payload["version"].to_i == CACHE_VERSION &&
        payload["max_depth"].to_i == MAX_DEPTH &&
        payload["roots"].is_a?(Array)
    end
    private_class_method :cached_payload_current?

    def self.cache_file_fresh?(cache_store)
      tree_path = cache_store.absolute(CACHE_PATH)
      manifest_path = cache_store.absolute(Manifest::CACHE_PATH)
      tree_path.file? && (!manifest_path.file? || tree_path.mtime >= manifest_path.mtime)
    rescue Errno::ENOENT
      false
    end
    private_class_method :cache_file_fresh?

    def initialize(manifest:, cache_store: CacheStore.new)
      @manifest = manifest
      @cache_store = cache_store
      @manifest_generated_at = manifest.respond_to?(:generated_at) ? manifest.generated_at.to_s : ""
      @roots = []
    end

    def load_cached_or_build!
      cached = @cache_store.read_json(CACHE_PATH)

      if cache_current?(cached)
        load_from_payload(cached)
      else
        @roots = build_roots
        @cache_store.write_json(
          CACHE_PATH,
          {
            "version" => CACHE_VERSION,
            "manifest_generated_at" => @manifest_generated_at,
            "max_depth" => MAX_DEPTH,
            "roots" => @roots
          }
        )
      end

      self
    end

    def empty?
      @roots.empty?
    end

    private

    def load_from_payload(payload)
      @manifest_generated_at = payload["manifest_generated_at"].to_s
      @roots = Array(payload["roots"])
      self
    end

    def build_roots
      nodes = {}

      Array(@manifest.documents).each do |document|
        role = document["document_role"].to_s
        role = DocumentRole.classify(document["path"]) if role.empty?
        next unless DocumentRole.searchable?(role)

        parts = folder_parts(document)
        next if parts.empty?

        1.upto([parts.length, MAX_DEPTH].min) do |depth|
          path = parts.first(depth).join("/")
          node = nodes[path] ||= new_node(path: path, name: parts.fetch(depth - 1), depth: depth)
          node["document_count"] += 1
          node["role_counts"][role] = node["role_counts"].fetch(role, 0) + 1
        end
      end

      nodes.each_value do |node|
        next if node["depth"] >= MAX_DEPTH

        child_depth = node["depth"] + 1
        node["children"] = nodes.values.select do |candidate|
          candidate["depth"] == child_depth && parent_path(candidate["path"]) == node["path"]
        end
        node["children"] = sort_nodes(node["children"])
      end

      sort_nodes(nodes.values.select { |node| node["depth"] == 1 })
    end

    def folder_parts(document)
      folder = document["folder_path"].to_s
      folder = File.dirname(document["path"].to_s) if folder.empty?
      return [] if folder == "."

      folder.tr("\\", "/").split("/").reject(&:empty?)
    end

    def new_node(path:, name:, depth:)
      {
        "path" => path,
        "name" => name,
        "depth" => depth,
        "document_count" => 0,
        "role_counts" => {},
        "children" => []
      }
    end

    def parent_path(path)
      parts = path.to_s.split("/")
      parts[0...-1].join("/")
    end

    def sort_nodes(nodes)
      Array(nodes).sort_by do |node|
        name = node["name"].to_s
        if node["depth"].to_i == 1
          preferred = PREFERRED_ROOT_ORDER.index(name)
          [preferred.nil? ? 1 : 0, preferred || 99_999, name]
        else
          [LAYER_ORDER.fetch(name, 10), name]
        end
      end
    end

    def cache_current?(payload)
      payload.is_a?(Hash) &&
        payload["version"].to_i == CACHE_VERSION &&
        payload["manifest_generated_at"].to_s == @manifest_generated_at &&
        payload["max_depth"].to_i == MAX_DEPTH
    end
  end
end
