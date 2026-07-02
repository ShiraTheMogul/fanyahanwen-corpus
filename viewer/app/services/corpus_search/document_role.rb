# frozen_string_literal: true

module CorpusSearch
  # Classifies a corpus file from its path. This is derived search-index data;
  # it never writes new metadata into the corpus file itself.
  class DocumentRole
    ROLES = %w[
      canonical
      textual_variant
      raw
      derived_reading
      translation
      annotation
      support
    ].freeze

    DEFAULT_ROLES = %w[canonical].freeze
    SEARCHABLE_ROLES = (ROLES - %w[support]).freeze

    DERIVED_SEGMENTS = %w[kanbun hanmun hanvan].freeze
    TRANSLATION_SEGMENTS = %w[translation translations].freeze
    ANNOTATION_SEGMENTS = %w[annotation annotations].freeze

    class << self
      def classify(path)
        parts = segments(path)
        lowered = parts.map(&:downcase)

        # Raw wins over every other role. A source scrape may itself contain a
        # folder called variants or translation, but it is still raw material.
        return "raw" if lowered.include?("raw")
        return "textual_variant" if lowered.include?("variants")
        return "derived_reading" if (lowered & DERIVED_SEGMENTS).any?
        return "translation" if (lowered & TRANSLATION_SEGMENTS).any?
        return "annotation" if (lowered & ANNOTATION_SEGMENTS).any?
        return "canonical" if lowered.include?("clean")

        "support"
      end

      def canonical_parent_path(path)
        parts = segments(path)
        index = parts.map(&:downcase).index("variants")
        return nil unless index

        parts[0...index].join("/")
      end

      def folder_path(path)
        directory = File.dirname(normalize(path))
        directory == "." ? "" : directory
      end

      def searchable?(role)
        SEARCHABLE_ROLES.include?(role.to_s)
      end

      def default?(role)
        DEFAULT_ROLES.include?(role.to_s)
      end

      private

      def segments(path)
        normalize(path).split("/").reject(&:empty?)
      end

      def normalize(path)
        path.to_s.tr("\\", "/").sub(%r{\A/+}, "")
      end
    end
  end
end
