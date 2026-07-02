# frozen_string_literal: true

module CorpusSearch
  # Display-only settings for an already-defined search.
  class PresentationOptions
    attr_reader :context, :page, :per_page

    def initialize(context: 20, page: 1, per_page: 20)
      @context = clamp_integer(context, default: 20, min: 0, max: 200)
      @page = clamp_integer(page, default: 1, min: 1, max: 100_000)
      @per_page = clamp_integer(per_page, default: 20, min: 1, max: 50)
      freeze
    end

    def to_h
      {
        "context" => @context,
        "page" => @page,
        "per_page" => @per_page
      }
    end

    private

    def clamp_integer(value, default:, min:, max:)
      integer = Integer(value)
      [[integer, min].max, max].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
