# frozen_string_literal: true

module CorpusSearch
  # Compatibility wrapper. New search code should use DocumentReader directly.
  class FrontMatter
    LABEL_MAP = DocumentReader::LABEL_MAP

    def self.split(raw)
      DocumentReader.split(raw)
    end

    def initialize(raw)
      @raw = raw
    end

    def split
      self.class.split(@raw)
    end
  end
end
