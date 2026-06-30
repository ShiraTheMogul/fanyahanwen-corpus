# frozen_string_literal: true

module Grammar
  # Validates the small, declarative search definitions stored beside grammar
  # entries. These values become ordinary corpus-search query parameters; they
  # never execute code or run a search while an article is being loaded.
  module CorpusSearchDefinition
    module_function

    MODES = %w[exact proximity].freeze
    ORDERS = %w[either a_before_b b_before_a].freeze
    FILTER_KEYS = %w[nation period region author year_start year_end].freeze
    ALLOWED_KEYS = %w[label mode term_a term_b distance context order].freeze + FILTER_KEYS

    def normalize_all(value)
      Array(value).map { |row| normalize(row) }
    end

    def normalize(value)
      raise ArgumentError, "Each grammar corpus search must be a key/value mapping" unless value.is_a?(Hash)

      row = MarkdownDocument.stringify_keys(value).slice(*ALLOWED_KEYS)
      mode = row["mode"].to_s.presence || "exact"
      raise ArgumentError, "Unknown grammar corpus search mode: #{mode}" unless MODES.include?(mode)

      term_a = row["term_a"].to_s.strip
      term_b = row["term_b"].to_s.strip
      raise ArgumentError, "A grammar corpus search requires term_a" if term_a.blank?
      raise ArgumentError, "A proximity grammar search requires term_b" if mode == "proximity" && term_b.blank?
      if [term_a, term_b].any? { |term| term.each_char.count > 80 }
        raise ArgumentError, "Grammar corpus search terms cannot exceed 80 characters"
      end

      normalized = {
        "mode" => mode,
        "term_a" => term_a
      }
      normalized["term_b"] = term_b if term_b.present?
      normalized["label"] = row["label"].to_s.strip if row["label"].present?
      normalized["distance"] = bounded_integer(row["distance"], default: 200, min: 1, max: 5_000) if row.key?("distance")
      normalized["context"] = bounded_integer(row["context"], default: 20, min: 0, max: 200) if row.key?("context")

      order = row["order"].to_s.presence || "either"
      raise ArgumentError, "Unknown grammar corpus search order: #{order}" unless ORDERS.include?(order)
      normalized["order"] = order if mode == "proximity" || row.key?("order")

      FILTER_KEYS.each do |key|
        normalized[key] = row[key].to_s.strip if row[key].present?
      end

      normalized
    end

    def bounded_integer(value, default:, min:, max:)
      integer = Integer(value)
      raise ArgumentError, "Grammar corpus search number must be between #{min} and #{max}" unless integer.between?(min, max)

      integer
    rescue TypeError, ArgumentError => e
      raise e if e.is_a?(ArgumentError) && e.message.start_with?("Grammar corpus search number")

      default
    end
    private_class_method :bounded_integer
  end
end
