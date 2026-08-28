# frozen_string_literal: true

module CorpusSearch
  # One compiled user-supplied regular expression reused across every document
  # in a query. Matches are found on the same NormalizedText stream used by the
  # other corpus-search modes, so punctuation handling and source-offset mapping
  # remain consistent.
  #
  # The lifecycle is deliberately influenced by Notepad++'s regex Find in Files:
  # compile once, scan forward through each UTF-8 document, and make zero-width
  # matches advance safely. Notepad++'s implementation is GPL; this class is an
  # independent Ruby implementation and does not copy its source.
  # Reference implementation studied:
  # https://github.com/notepad-plus-plus/notepad-plus-plus/blob/c057c08028b4d40490c6e21bf87a18e95cc3e318/boostregex/BoostRegExSearch.cxx
  class RegexPattern
    DEFAULT_TIMEOUT_SECONDS = 0.5

    class MatchTimeout < ArgumentError; end

    attr_reader :source, :regexp

    def self.validation_error(source)
      Regexp.new(source.to_s)
      nil
    rescue RegexpError, ArgumentError => e
      e.message
    end

    def self.timeout_seconds
      value = Float(ENV.fetch("CORPUS_SEARCH_REGEX_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS.to_s))
      value.positive? ? value : DEFAULT_TIMEOUT_SECONDS
    rescue ArgumentError, TypeError
      DEFAULT_TIMEOUT_SECONDS
    end

    def initialize(source, timeout: self.class.timeout_seconds)
      @source = source.to_s
      @regexp = Regexp.new(@source, timeout: timeout)
      freeze
    rescue RegexpError => e
      raise ArgumentError, e.message
    end

    # Return non-empty half-open ranges in normalized character offsets.
    # String#scan keeps the regex engine moving forward in native code. Reading
    # MatchData#begin repeatedly is surprisingly expensive on a long UTF-8 Han
    # string because Ruby has to translate byte positions into character offsets.
    # byteoffset gives us the engine's native positions; SearchText then converts
    # all unique endpoints in one forward pass.
    def ranges_in(searchable)
      byte_ranges = []

      character_ranges = []
      searchable.text.scan(@regexp) do
        match = Regexp.last_match
        if match.respond_to?(:byteoffset)
          search_start, search_end = match.byteoffset(0)
          next if search_start.nil? || search_end.nil? || search_end <= search_start

          byte_ranges << [search_start, search_end]
        else
          # Compatibility path for older supported Rubies without byteoffset.
          search_start = match.begin(0)
          search_end = match.end(0)
          next if search_start.nil? || search_end.nil? || search_end <= search_start

          character_ranges << [search_start, search_end]
        end
      end

      return character_ranges if byte_ranges.empty?

      SearchText.character_ranges_for_byte_ranges(searchable.text, byte_ranges)
    rescue Regexp::TimeoutError => e
      raise MatchTimeout, "regular expression exceeded the per-document time limit (#{e.message})"
    end
  end
end
