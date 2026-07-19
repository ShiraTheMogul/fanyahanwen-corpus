# frozen_string_literal: true

require "json"
require "pathname"

module Atlas
  # Loads the deliberately small historical navigation tree stored in
  # content/atlas/hierarchy.json. The corpus may contain hundreds of thousands
  # of work folders; this tree records only the folder levels that carry
  # historical meaning, such as corpus root, period, polity, or territory.
  class CorpusHierarchy
    ROOT = Rails.root.join("content", "atlas", "hierarchy.json")

    class Node
      attr_reader :attributes, :parent

      def initialize(attributes, parent: nil)
        @attributes = Grammar::MarkdownDocument.stringify_keys(attributes.to_h)
        @parent = parent
        @children = Array(@attributes["children"]).filter_map do |child|
          child.is_a?(Hash) ? self.class.new(child, parent: self) : nil
        end
      end

      def path = attributes["path"].to_s
      def label = attributes["label"].to_s.presence || path.split("/").last.to_s
      def kind = attributes["kind"].to_s.presence || "folder"
      def entry_id = attributes["entry_id"].to_s.presence
      def description = attributes["description"].to_s
      def children = @children
      def root? = parent.nil?
      def leaf? = children.empty?
      def discover_children_as = attributes["discover_children_as"].to_s.presence
      def descendant_directory_count = attributes["descendant_directory_count"].to_i

      def corpus_path
        return nil if root? || path.blank?

        pieces = path.split("/")
        [pieces.first, "clean", *pieces.drop(1)].join("/")
      end
    end

    attr_reader :path

    def self.default = new

    def initialize(path: ROOT)
      @path = Pathname.new(path)
    end

    def root
      @root ||= Node.new(
        {
          "path" => "",
          "label" => I18n.t("atlas.title"),
          "kind" => "atlas_root",
          "children" => payload.fetch("roots")
        }
      )
    end

    def find(path_value)
      normalized = normalize_path(path_value)
      return root if normalized.blank?

      nodes_by_path[normalized]
    end

    def find!(path_value)
      find(path_value) || raise(ActiveRecord::RecordNotFound, "Unknown atlas folder")
    end

    def ancestors(node)
      rows = []
      current = node.parent
      while current
        rows << current
        current = current.parent
      end
      rows.reverse
    end

    def all_nodes
      @all_nodes ||= begin
        rows = []
        walk = lambda do |node|
          rows << node
          node.children.each { |child| walk.call(child) }
        end
        walk.call(root)
        rows.freeze
      end
    end

    def validate!(entry_store: nil)
      paths = all_nodes.reject(&:root?).map(&:path)
      duplicates = paths.group_by(&:itself).select { |_path, rows| rows.length > 1 }.keys
      raise ArgumentError, "Duplicate atlas hierarchy paths: #{duplicates.join(', ')}" if duplicates.any?

      all_nodes.reject(&:root?).each do |node|
        raise ArgumentError, "Atlas hierarchy path is blank" if node.path.blank?
        raise ArgumentError, "Atlas hierarchy child escapes parent: #{node.path}" unless child_of_parent?(node)

        if entry_store && node.entry_id.present? && entry_store.find(node.entry_id).nil?
          raise ArgumentError, "Unknown atlas hierarchy entry: #{node.entry_id}"
        end
      end
      true
    end

    private

    def payload
      return load_payload if Rails.env.development?
      @payload ||= load_payload
    end

    def load_payload
      parsed = JSON.parse(path.binread.force_encoding("UTF-8").scrub)
      raise ArgumentError, "Atlas hierarchy must be a key/value mapping" unless parsed.is_a?(Hash)
      raise ArgumentError, "Atlas hierarchy roots must be a list" unless parsed["roots"].is_a?(Array)

      parsed
    rescue Errno::ENOENT
      { "version" => 1, "roots" => [] }
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid atlas hierarchy JSON: #{e.message}"
    end

    def nodes_by_path
      @nodes_by_path ||= all_nodes.reject(&:root?).index_by(&:path)
    end

    def normalize_path(value)
      value.to_s.split("/").reject(&:blank?).join("/")
    end

    def child_of_parent?(node)
      return true if node.parent&.root?

      node.path.start_with?(node.parent.path + "/")
    end
  end
end
