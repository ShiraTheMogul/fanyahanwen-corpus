# frozen_string_literal: true

require "pathname"

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
        # Web requests are cache-only. Never traverse the corpus filesystem while
        # rendering the search form: on WSL/OneDrive, even a shallow directory
        # walk can block the request for more than a minute. The maintenance task
        # rebuilds this cache immediately after rebuilding the manifest.
        cached = cache_store.read_json(CACHE_PATH)
        tree = new(manifest: nil, cache_store: cache_store)
        tree.send(:load_from_payload, cached) if cached_payload_current?(cached)
        return tree
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

    def load_filesystem_tree!
      @manifest_generated_at = "filesystem"
      @roots = build_roots_from_filesystem
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
      return build_roots_from_filesystem unless @manifest

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

      attach_children!(nodes)
      sort_nodes(nodes.values.select { |node| node["depth"] == 1 })
    end


    def build_roots_from_filesystem
      root = Pathname(Rails.configuration.x.corpus_root.to_s).expand_path
      return [] unless root.directory?

      nodes = {}
      queue = [[root, [], 0]]

      until queue.empty?
        directory, parts, depth = queue.shift
        next if depth >= MAX_DEPTH

        Dir.children(directory).sort.each do |entry|
          next if entry.start_with?(".")
          next if Manifest::DEFAULT_SKIP_DIRS.include?(entry)

          path = directory.join(entry)
          next unless path.directory?

          child_parts = parts + [entry]
          child_depth = child_parts.length
          corpus_path = child_parts.join("/")
          nodes[corpus_path] ||= new_node(path: corpus_path, name: entry, depth: child_depth)
          queue << [path, child_parts, child_depth] if child_depth < MAX_DEPTH
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError
          next
        end
      end

      attach_children!(nodes)
      sort_nodes(nodes.values.select { |node| node["depth"] == 1 })
    end

    def attach_children!(nodes)
      children_by_parent = Hash.new { |hash, key| hash[key] = [] }

      nodes.each_value do |node|
        next if node["depth"].to_i <= 1

        children_by_parent[parent_path(node["path"])] << node
      end

      nodes.each_value do |node|
        next if node["depth"].to_i >= MAX_DEPTH

        node["children"] = sort_nodes(children_by_parent[node["path"]])
      end
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
