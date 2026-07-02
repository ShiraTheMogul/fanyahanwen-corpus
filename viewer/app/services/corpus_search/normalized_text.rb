# frozen_string_literal: true

module CorpusSearch
  # A searchable character stream plus a map back to the original body offsets.
  # Search offsets are character indexes, never byte indexes.
  class NormalizedText
    PUNCTUATION_MODES = %w[ignore respect].freeze

    attr_reader :units, :original_offsets, :punctuation, :profile_version

    def self.build(text, punctuation: "ignore", profile: NormalizationProfile.current)
      new(text, punctuation: punctuation, profile: profile)
    end

    def initialize(text, punctuation: "ignore", profile: NormalizationProfile.current)
      @punctuation = PUNCTUATION_MODES.include?(punctuation.to_s) ? punctuation.to_s : "ignore"
      @profile_version = profile.version
      @units = []
      @original_offsets = []

      text.to_s.each_char.with_index do |character, original_offset|
        next if @punctuation == "ignore" && profile.ignored?(character)

        @units << character
        @original_offsets << original_offset
      end

      @units.freeze
      @original_offsets.freeze
      @text = @units.join.freeze
      freeze
    end

    def text
      @text
    end

    def empty?
      @units.empty?
    end

    # Convert a half-open searchable range into a half-open range in the
    # original body. Punctuation between the first and final matched units is
    # therefore included in the displayed source span.
    def original_range(search_start, search_end)
      start_index = Integer(search_start)
      end_index = Integer(search_end)
      return nil if start_index.negative? || end_index <= start_index
      return nil if start_index >= @original_offsets.length || end_index > @original_offsets.length

      [@original_offsets.fetch(start_index), @original_offsets.fetch(end_index - 1) + 1]
    rescue ArgumentError, TypeError, IndexError
      nil
    end
  end
end
