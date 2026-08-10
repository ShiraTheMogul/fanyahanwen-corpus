# frozen_string_literal: true

require "open-uri"

module CharacterData
  module Utf8Stream
    module_function

    # Open source data as bytes first, then tell Ruby how those bytes should be
    # decoded. This works for both normal files and open-uri streams.
    #
    # We deliberately do not use "r:bom|utf-8" here: File.open understands
    # that mode, but open-uri treats "bom|utf-8" as a literal Encoding name.
    # Importers already remove a leading U+FEFF when they parse each line.
    def open(path: nil, url: nil, read_timeout: 60)
      stream =
        if path && !path.to_s.empty?
          File.open(path, "rb")
        elsif url && !url.to_s.empty?
          URI.open(url, "rb", read_timeout: read_timeout)
        else
          raise ArgumentError, "provide a path or URL"
        end

      stream.set_encoding(Encoding::UTF_8)
      stream
    end
  end
end
