# frozen_string_literal: true

require "json"

class IsoLanguageRegistry
  DATA_PATH = Rails.root.join("public", "iso_639_3.json")

  class << self
    def all
      @all ||= begin
        rows = JSON.parse(File.read(DATA_PATH, encoding: "UTF-8"))
        rows.filter_map do |row|
          code = row["code"].to_s.downcase
          name = row["name"].to_s.strip
          next unless code.match?(/\A[a-z]{3}\z/) && name.present?

          { "code" => code, "name" => name }
        end.freeze
      end
    end

    def include?(code)
      names_by_code.key?(code.to_s.downcase)
    end

    def name_for(code)
      names_by_code[code.to_s.downcase]
    end

    private

    def names_by_code
      @names_by_code ||= all.to_h { |row| [row["code"], row["name"]] }.freeze
    end
  end
end
