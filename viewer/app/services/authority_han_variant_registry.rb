# frozen_string_literal: true

require "digest"
require "set"
require "singleton"

# Small, file-backed Han orthography registry for authority names and work titles.
#
# Interactive historical tools have a narrow matching problem: accept controlled
# simplified/traditional and Japanese shinjitai spellings of the same name. They
# do not need the much larger corpus VariantMapping graph used by full-text
# character-equivalence search. Keeping this registry file-backed means an era
# lookup never queries VariantMapping merely to normalise a name.
class AuthorityHanVariantRegistry
  include Singleton

  OPENCC_DIRECTORY = Rails.root.join("resources", "corpus_search", "opencc")
  OPENCC_DICTIONARIES = {
    "STCharacters.txt" => "opencc_simplified_traditional",
    "TSCharacters.txt" => "opencc_simplified_traditional",
    "JPShinjitaiCharacters.txt" => "opencc_japanese_shinjitai"
  }.freeze

  Edge = Data.define(:from, :to, :source, :detail)

  attr_reader :version

  def initialize
    @graph = build_graph
    @version = build_version
    @forms_cache = {}
  end

  def forms_for(character)
    unit = character.to_s
    return Set.new.freeze if unit.empty?
    return @forms_cache[unit] if @forms_cache.key?(unit)

    # One mapping hop is deliberate. Simplification can collapse distinct
    # traditional characters onto the same simplified form (for example 發 and
    # 髮 both map through 发). A transitive connected component would then claim
    # those distinct traditional forms are interchangeable in a personal or era
    # name. A simplified input can still match either direct traditional mapping,
    # but one traditional form does not become an alias of its sibling.
    forms = Set[unit]
    Array(@graph[unit]).each { |edge| forms << edge.to }
    @forms_cache[unit] = forms.freeze
  end

  def equivalent?(left, right)
    left.to_s == right.to_s || forms_for(left).include?(right.to_s)
  end

  def explanation(query_character:, source_character:)
    source = query_character.to_s
    target = source_character.to_s
    return nil if source.empty? || target.empty? || source == target

    edges = Array(@graph[source]).select { |edge| edge.to == target }
    return nil if edges.empty?

    {
      "query_character" => source,
      "source_character" => target,
      "mapping_path" => [source, target],
      "mapping_sources" => edges.map(&:source).uniq,
      "mapping_details" => edges.map(&:detail).compact.uniq,
      "equivalence_level" => "authority_static_direct",
      "equivalence_version" => version
    }
  end

  private

  def build_graph
    graph = Hash.new { |hash, key| hash[key] = [] }
    seen = Set.new

    OPENCC_DICTIONARIES.each do |filename, source|
      path = OPENCC_DIRECTORY.join(filename)
      next unless path.file?

      path.open("r:bom|utf-8") do |io|
        io.each_line(chomp: true) do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          left, values = stripped.split(/\t+/, 2)
          next unless single_character?(left) && values

          values.split(/\s+/).each do |right|
            next unless single_character?(right)
            next if left == right

            key = [left, right].sort + [source]
            next if seen.include?(key)

            seen << key
            graph[left] << Edge.new(from: left, to: right, source: source, detail: filename)
            graph[right] << Edge.new(from: right, to: left, source: source, detail: filename)
          end
        end
      end
    end

    graph.each_value(&:freeze)
    graph.default_proc = nil
    graph.freeze
  end

  def build_version
    digest = Digest::SHA256.new
    digest << "authority-static-v2-direct\0"
    OPENCC_DICTIONARIES.each_key do |filename|
      path = OPENCC_DIRECTORY.join(filename)
      digest << filename << "\0"
      digest << (path.file? ? Digest::SHA256.file(path).hexdigest : "missing")
      digest << "\0"
    end
    "authority-static-#{digest.hexdigest[0, 16]}"
  end


  def single_character?(value)
    value.to_s.each_char.count == 1
  end
end
