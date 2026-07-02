# frozen_string_literal: true

require "yaml"
require "set"

module CorpusSearch
  # Versioned rules for turning a displayed corpus body into a searchable stream.
  # The source text is never rewritten; these rules only decide which characters
  # participate in matching when punctuation is ignored.
  class NormalizationProfile
    CONFIG_PATH = Rails.root.join("config", "corpus_search_normalization.yml")

    CATEGORY_PATTERNS = {
      "punctuation" => /\p{P}/u,
      "separators" => /\p{Z}/u
    }.freeze

    CLASS_PATTERNS = {
      "whitespace" => /[[:space:]]/u
    }.freeze

    class << self
      def current
        @current ||= new(YAML.safe_load_file(CONFIG_PATH, aliases: false) || {})
      end

      def reset!
        @current = nil
      end
    end

    attr_reader :version

    def initialize(config)
      @version = Integer(config.fetch("version", 1))
      rules = config.fetch("ignore_when_punctuation_is_ignored", {})
      @category_patterns = Array(rules["unicode_categories"]).filter_map { |name| CATEGORY_PATTERNS[name.to_s] }.freeze
      @class_patterns = Array(rules["character_classes"]).filter_map { |name| CLASS_PATTERNS[name.to_s] }.freeze
      @codepoints = Array(rules["codepoints"]).map { |value| Integer(value.to_s, 16) }.to_set.freeze
      freeze
    end

    def ignored?(character)
      char = character.to_s
      return false if char.empty?
      return true if @codepoints.include?(char.ord)
      return true if @category_patterns.any? { |pattern| char.match?(pattern) }

      @class_patterns.any? { |pattern| char.match?(pattern) }
    end
  end
end
