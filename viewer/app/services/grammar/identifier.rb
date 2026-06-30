# frozen_string_literal: true

require "set"

module Grammar
  # Generates stable, readable identifiers without depending on a pronunciation.
  #
  # Han characters are represented by Unicode code points:
  #   之 -> u4e4b
  #   以……為 -> u4ee5-u70ba
  #
  # The generator reports collisions; it never silently replaces an existing ID.
  class Identifier
    PREFIXES = {
      "function_word" => "fw",
      "function" => "function",
      "pattern" => "pattern",
      "binome" => "binome",
      "comparison" => "comparison",
      "concept" => "concept"
    }.freeze

    class << self
      def generate(kind:, headword:, parent_id: nil, label: nil)
        kind = kind.to_s
        prefix = PREFIXES.fetch(kind, normalise_ascii(kind).presence || "entry")

        if kind == "function" && parent_id.to_s.present?
          suffix = normalise_ascii(label.to_s).presence || tokenise(headword)
          return [parent_id.to_s, suffix].reject(&:blank?).join("-")
        end

        token = tokenise(headword)
        token = normalise_ascii(label.to_s) if token.blank?
        [prefix, token.presence || "entry"].join("-")
      end

      def collision?(candidate, existing_ids)
        Array(existing_ids).map(&:to_s).include?(candidate.to_s)
      end

      def next_available(candidate, existing_ids)
        ids = Array(existing_ids).map(&:to_s).to_set
        return candidate unless ids.include?(candidate)

        number = 2
        number += 1 while ids.include?("#{candidate}-#{number}")
        "#{candidate}-#{number}"
      end

      private

      def tokenise(value)
        value.to_s.scan(/\p{Han}|[A-Za-z0-9]+/).map do |token|
          if token.match?(/\A\p{Han}\z/)
            "u#{token.ord.to_s(16)}"
          else
            normalise_ascii(token)
          end
        end.reject(&:blank?).join("-")
      end

      def normalise_ascii(value)
        value.to_s
             .downcase
             .encode("ASCII", invalid: :replace, undef: :replace, replace: " ")
             .gsub(/[^a-z0-9]+/, "-")
             .gsub(/\A-+|-+\z/, "")
      end
    end
  end
end
