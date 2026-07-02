# frozen_string_literal: true

require "digest"
require "set"
require "thread"
require "time"

module CorpusSearch
  # One shared, read-only registry for search-time character equivalence.
  #
  # Stored corpus text is never rewritten. The registry expands each query
  # character into a controlled set of acceptable source forms and retains the
  # provenance needed to explain non-literal matches.
  class CharacterEquivalenceRegistry
    LEVELS = %w[exact common broad].freeze
    OPENCC_DIRECTORY = Rails.root.join("resources", "corpus_search", "opencc")
    OPENCC_DICTIONARIES = {
      "STCharacters.txt" => "opencc_simplified_traditional",
      "TSCharacters.txt" => "opencc_simplified_traditional",
      "JPShinjitaiCharacters.txt" => "opencc_japanese_shinjitai"
    }.freeze

    Edge = Data.define(:from, :to, :source, :detail)

    @graph_cache = {}
    @graph_cache_mutex = Mutex.new

    class << self
      def version_for(level)
        chosen = normalize_level(level)
        return "exact-v1" if chosen == "exact"

        common_version = Digest::SHA256.hexdigest(
          ["common-v1", variant_mapping_version].join(":"),
        )[0, 16]
        return "common-#{common_version}" if chosen == "common"

        broad_version = Digest::SHA256.hexdigest(
          ["broad-v1", common_version, opencc_digest].join(":"),
        )[0, 16]
        "broad-#{broad_version}"
      end

      def graph_for(level)
        chosen = normalize_level(level)
        return {}.freeze if chosen == "exact"

        key = [chosen, version_for(chosen)]
        @graph_cache_mutex.synchronize do
          @graph_cache[key] ||= build_graph(chosen)
          @graph_cache.delete_if { |cached_key, _value| cached_key.first == chosen && cached_key != key }
          @graph_cache.fetch(key)
        end
      end

      def normalize_level(level)
        candidate = level.to_s
        LEVELS.include?(candidate) ? candidate : "common"
      end

      def reset_cache!
        @graph_cache_mutex.synchronize { @graph_cache.clear }
      end

      private

      def build_graph(level)
        graph = Hash.new { |hash, character| hash[character] = [] }
        seen = Set.new

        add_variant_mapping_edges(graph, seen)
        add_opencc_edges(graph, seen) if level == "broad"

        graph.each_value(&:freeze)
        graph.default_proc = nil
        graph.freeze
      end

      def add_variant_mapping_edges(graph, seen)
        return unless variant_mapping_available?

        VariantMapping.unscoped.pluck(:base_codepoint, :variant_codepoint, :source).each do |base_cp, variant_cp, source|
          next unless valid_codepoint?(base_cp) && valid_codepoint?(variant_cp)

          source_code = source.to_s.match?(/Zetian|則天/i) ? "zetian_script" : "taiwan_moe"
          add_edge(
            graph,
            seen,
            [base_cp].pack("U"),
            [variant_cp].pack("U"),
            source: source_code,
            detail: source.to_s.presence
          )
        end
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        nil
      end

      def add_opencc_edges(graph, seen)
        OPENCC_DICTIONARIES.each do |filename, source_code|
          path = OPENCC_DIRECTORY.join(filename)
          next unless path.file?

          path.open("r:bom|utf-8") do |dictionary|
            dictionary.each_line(chomp: true) do |line|
              stripped = line.strip
              next if stripped.empty? || stripped.start_with?("#")

              key, values = stripped.split(/\t+/, 2)
              next unless single_character?(key) && values.present?

              values.split(/\s+/).each do |value|
                next unless single_character?(value)

                add_edge(
                  graph,
                  seen,
                  key,
                  value,
                  source: source_code,
                  detail: filename
                )
              end
            end
          end
        end
      end

      def add_edge(graph, seen, left, right, source:, detail: nil)
        return if left == right

        key = [left, right].sort + [source]
        return if seen.include?(key)

        seen << key
        graph[left] << Edge.new(from: left, to: right, source: source, detail: detail)
        graph[right] << Edge.new(from: right, to: left, source: source, detail: detail)
      end

      def variant_mapping_version
        return "unavailable" unless variant_mapping_available?

        relation = VariantMapping.unscoped
        count = relation.count
        maximum_updated_at = relation.maximum(:updated_at)&.utc&.iso8601(6)
        maximum_id = relation.maximum(:id)
        "#{count}:#{maximum_id}:#{maximum_updated_at}"
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        "unavailable"
      end

      def variant_mapping_available?
        defined?(VariantMapping) && VariantMapping.table_exists?
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        false
      end

      def opencc_digest
        digest = Digest::SHA256.new
        OPENCC_DICTIONARIES.each_key do |filename|
          path = OPENCC_DIRECTORY.join(filename)
          digest << filename << "\0"
          digest << (path.file? ? path.binread : "missing")
          digest << "\0"
        end
        digest.hexdigest
      end

      def valid_codepoint?(value)
        integer = Integer(value)
        integer.between?(0, 0x10FFFF) && !integer.between?(0xD800, 0xDFFF)
      rescue ArgumentError, TypeError
        false
      end

      def single_character?(value)
        value.to_s.each_char.count == 1
      end
    end

    attr_reader :level, :version

    def initialize(level: "common")
      @level = self.class.normalize_level(level)
      @version = self.class.version_for(@level)
      @graph = self.class.graph_for(@level)
      @forms_cache = {}
      @path_cache = {}
    end

    def exact?
      @level == "exact"
    end

    def forms_for(character)
      unit = character.to_s
      return Set.new.freeze if unit.empty?
      return Set[unit].freeze if exact? || !@graph.key?(unit)

      @forms_cache[unit] ||= connected_component(unit).freeze
    end

    def equivalent?(left, right)
      left.to_s == right.to_s || forms_for(left).include?(right.to_s)
    end

    # Returns an inspectable provenance path for a non-literal match.
    def explanation(query_character:, source_character:)
      query_unit = query_character.to_s
      source_unit = source_character.to_s
      return nil if query_unit.empty? || source_unit.empty? || query_unit == source_unit

      path = shortest_path(query_unit, source_unit)
      return nil unless path

      {
        "query_character" => query_unit,
        "source_character" => source_unit,
        "mapping_path" => [query_unit, *path.map(&:to)],
        "mapping_sources" => path.map(&:source).uniq,
        "mapping_details" => path.map(&:detail).compact.uniq,
        "equivalence_level" => @level,
        "equivalence_version" => @version
      }
    end

    private

    def connected_component(start)
      visited = Set[start]
      queue = [start]

      until queue.empty?
        current = queue.shift
        Array(@graph[current]).each do |edge|
          next if visited.include?(edge.to)

          visited << edge.to
          queue << edge.to
        end
      end

      visited
    end

    def shortest_path(start, target)
      cache_key = [start, target]
      return @path_cache[cache_key] if @path_cache.key?(cache_key)
      return @path_cache[cache_key] = nil unless forms_for(start).include?(target)

      queue = [start]
      previous = { start => nil }
      previous_edge = {}

      until queue.empty?
        current = queue.shift
        break if current == target

        Array(@graph[current]).each do |edge|
          next if previous.key?(edge.to)

          previous[edge.to] = current
          previous_edge[edge.to] = edge
          queue << edge.to
        end
      end

      unless previous.key?(target)
        @path_cache[cache_key] = nil
        return nil
      end

      path = []
      cursor = target
      while cursor != start
        edge = previous_edge.fetch(cursor)
        path << edge
        cursor = previous.fetch(cursor)
      end

      @path_cache[cache_key] = path.reverse.freeze
    end
  end
end
