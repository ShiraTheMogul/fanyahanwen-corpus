# frozen_string_literal: true

module DictionaryCatalogue
  # Converts a flat ordered section list into display groups that match the
  # dictionary's own organising system.
  #
  # Rhyme dictionaries keep their tone divisions. Dictionaries without tone
  # divisions use neutral sequence ranges so Kangxi and Shuowen do not appear
  # under a misleading "Other" tone heading.
  class SectionGrouping
    TONE_ORDER = %w[平聲 上聲 去聲 入聲].freeze
    RANGE_SIZE = 50
    FIRST_RANGE_END = 49

    def self.call(sections)
      new(sections).call
    end

    def initialize(sections)
      @sections = Array(sections).sort_by(&:sequence_number)
    end

    def call
      return { mode: :empty, groups: [] } if @sections.empty?

      if @sections.any? { |section| section.tone.to_s.strip != "" }
        { mode: :tone, groups: tone_groups }
      elsif @sections.length > RANGE_SIZE
        { mode: :sequence_range, groups: sequence_range_groups }
      else
        {
          mode: :single,
          groups: [
            {
              key: "all",
              label: I18n.t("dictionary.catalogue.sections", default: "Sections"),
              sections: @sections
            }
          ]
        }
      end
    end

    private

    def tone_groups
      grouped = @sections.group_by { |section| section.tone.to_s.strip.presence || "其他" }
      ordered_labels = TONE_ORDER.select { |tone| grouped.key?(tone) }
      ordered_labels.concat((grouped.keys - ordered_labels).sort)

      ordered_labels.map do |label|
        { key: label, label: label, sections: grouped.fetch(label) }
      end
    end

    def sequence_range_groups
      maximum = @sections.map(&:sequence_number).max
      grouped = @sections.group_by { |section| range_start(section.sequence_number) }

      grouped.keys.sort.map do |start_number|
        finish = [range_finish(start_number), maximum].min
        {
          key: "#{start_number}-#{finish}",
          label: "#{start_number}–#{finish}",
          sections: grouped.fetch(start_number)
        }
      end
    end

    def range_start(sequence_number)
      number = sequence_number.to_i
      return 1 if number < RANGE_SIZE

      (number / RANGE_SIZE) * RANGE_SIZE
    end

    def range_finish(start_number)
      start_number == 1 ? FIRST_RANGE_END : start_number + RANGE_SIZE - 1
    end
  end
end
