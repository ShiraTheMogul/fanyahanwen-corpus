# frozen_string_literal: true

module Grammar
  module Orcid
    module_function

    FORMAT = /\A\d{4}-\d{4}-\d{4}-\d{3}[\dX]\z/i

    def normalize(value)
      candidate = value.to_s.strip
      candidate = candidate.sub(%r{\Ahttps?://orcid\.org/}i, "")
      candidate = candidate.upcase
      return nil if candidate.blank?
      return candidate if valid?(candidate)

      raise ArgumentError, "ORCID must be a valid identifier such as 0000-0002-1825-0097"
    end

    def valid?(candidate)
      return false unless FORMAT.match?(candidate)

      digits = candidate.delete("-").chars
      check = digits.pop
      total = digits.reduce(0) { |sum, digit| (sum + digit.to_i) * 2 }
      remainder = (12 - (total % 11)) % 11
      expected = remainder == 10 ? "X" : remainder.to_s
      expected == check
    end
  end
end
