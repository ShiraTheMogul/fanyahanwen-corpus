# frozen_string_literal: true

module CharacterQuery
  # The corpus's own rime books and character dictionaries, as pickable
  # sources.
  #
  # WHY THIS EXISTS
  #
  # A tone or a rhyme category is a claim made BY a book. 上聲 is not one
  # category shared by the tradition: 廣韻 files 3,713 characters under it,
  # 集韻 5,960, 五音集韻 6,273, 切韻 2,180, 洪武正韻 2,603. Those are five
  # editorial judgements made between 601 and 1375, and merging them produces
  # a set that no compiler ever asserted. 韻目 is worse, because the graphs
  # collide: 麻 heads a section in six of these books and names a different
  # rime in each.
  #
  # A reconstruction is a different kind of thing again. Baxter & Sagart,
  # Pulleyblank and Karlgren are INTERPRETATIONS of the fanqie; the fanqie is
  # the attested datum. Presenting a Baxter syllable and a 廣韻 tone in one
  # row without naming either is the misattribution this module exists to
  # make impossible.
  #
  # WHAT IS DERIVED AND WHAT IS ASSERTED
  #
  # Derived from the data, so an import changes them with no code change:
  # which works qualify, which facets each one supports, and the vocabulary
  # of every facet.
  #
  # Asserted here, because a date is not in the table: the period each title
  # belongs to. The year is carried into the label so the claim is visible
  # rather than buried.
  module RimeBooks
    # PERIODS
    #
    # Two facts about a book pull in different directions, and they are kept
    # apart here on purpose:
    #
    #   WHEN IT WAS COMPILED        — its date, shown in every label.
    #   WHICH SYSTEM IT RECORDS     — what it is evidence FOR, which is what
    #                                 the picker groups by.
    #
    # They disagree for the Song books, and taking the date as the answer
    # would be the same class of error as the unscoped filter this module
    # replaced, one level up: it would file 廣韻's categories under a
    # phonology 廣韻 does not record.
    #
    # Pulleyblank puts 廣韻 in his chapter "The Sources of Early Middle
    # Chinese", and says why:
    #
    #   "Finally, in Song, the much enlarged Guangyun was published by
    #   imperial order and supplanted all previous versions... It is clear
    #   that while many more words were added in the course of time, the
    #   revisions did not, on the whole, disturb Lu Fayan's phonological
    #   categories."
    #     — Pulleyblank, Edwin G. (1984). Middle Chinese: A Study in
    #       Historical Phonology. Vancouver: UBC Press. ISBN 0-7748-0192-1.
    #
    # Late Middle Chinese for Pulleyblank is the rime-TABLE language, a
    # different dialect base: "the rhyme table language and the Qieyun
    # represent different dialects that are not in the same direct line", and
    # LMC is "similar in all essentials to the earliest rhyme table, the
    # Yunjing". The corpus holds no 韻鏡 and no 七音略, so the LMC branch is
    # defined and currently empty; FamilyRegistry drops an empty branch, so
    # nothing shows until such a source is imported.
    #
    # The corpus's own rhyme counts corroborate the grouping. Distinct 韻目
    # across all tones:
    #
    #   切韻 193   廣韻 199   集韻 176     — the 切韻 line, all of a size
    #   五音集韻 160   洪武正韻 76           — merged, and visibly later
    #
    # PERIOD BOUNDARY, for a book that declares no system
    #
    # Pulleyblank puts the shift at the end of the seventh century: LMC traits
    # are already in Yan Shigu's Hanshu glosses (completed 641), but "at least
    # to the end of the seventh century, a somewhat evolved form of Early
    # Middle Chinese, and not the Chang'an dialect, remained dominant at the
    # Tang court."
    #
    # The 中古 span itself is the 4th to the 12th century:
    #
    #   Xiang, Xi (2023). A Brief History of the Chinese Language II: From Old
    #   Chinese to Middle Chinese Phonetic System. London and New York:
    #   Routledge. ISBN 978-1-032-38108-4.
    MIDDLE_CHINESE_FROM = 301
    LATE_MIDDLE_CHINESE_FROM = 701
    MIDDLE_CHINESE_TO = 1200

    # title => the year of the recension the corpus holds, and the system it
    # is evidence for.
    #
    # 切韻 is dated to the lost 601 original rather than to either modern
    # reconstruction, because the reconstructions are attempts at that text
    # and not new books.
    #
    # 玉篇 here is the 大廣益會玉篇 recension, not 顧野王's 543 original. This
    # is the least comfortable entry: Pulleyblank uses the fanqie of "the
    # original Yupian composed during the Liang dynasty (as opposed to the
    # revised edition of the Song period)" as evidence for SOUTHERN Early
    # Middle Chinese, and sets the Song revision aside. So it is grouped with
    # EMC on the strength of the text it descends from, and its hint says
    # that the edition held here is the one he excluded.
    #
    # 五音集韻 rearranges 集韻 under the 36 initials, but it also MERGES: 160
    # rhyme categories against 集韻's 176 and 廣韻's 199. Mergers are sound
    # change, so it records a later system, not simply a reshelved earlier
    # one. 洪武正韻's 76 is further along again.
    #
    # 洪武正韻 is Ming, 1375, and was what the old filter was folding into
    # results labelled "Middle Chinese tone". It is not straightforwardly
    # Early Mandarin either: it was compiled to correct the vernacular, and
    # restored the 入聲 that 中原音韻 had already lost fifty years earlier.
    BOOKS = {
      "切韻" => { year: 601, records: "early_middle_chinese" },
      "廣韻" => { year: 1008, records: "early_middle_chinese" },
      "玉篇" => { year: 1013, records: "early_middle_chinese" },
      "集韻" => { year: 1039, records: "early_middle_chinese" },
      "五音集韻" => { year: 1212, records: "early_mandarin" },
      "洪武正韻" => { year: 1375, records: "early_mandarin" }
    }.freeze

    PERIOD_ORDER = %w[old_chinese early_middle_chinese late_middle_chinese
                      early_mandarin modern].freeze

    ID_PREFIX = "rimebook"

    module_function

    def reset!
      @books = nil
      @index = nil
      @vocabulary = nil
    end

    def id_for(work_id)
      "#{ID_PREFIX}:#{work_id}"
    end

    def id?(value)
      value.to_s.start_with?("#{ID_PREFIX}:")
    end

    def work_id_from(id)
      return nil unless id?(id)

      Integer(id.to_s.split(":", 2).last, exception: false)
    end

    # [{ id:, work_id:, title:, edition:, period:, year:, section_axis:,
    #    facets: [...], character_count: }]
    #
    # A work qualifies when it carries fanqie readings or tonal sections —
    # that is, when it says something about sound. 說文解字 and 康熙字典 carry
    # neither and do not appear.
    def books
      @books ||= load_books
    end

    def find(id)
      index[id.to_s]
    end

    def index
      @index ||= books.index_by { |book| book[:id] }
    end

    def for_period(period)
      books.select { |book| book[:period] == period.to_s }
    end

    def system_ids
      books.map { |book| book[:id] }
    end

    # Shaped like ReadingSystem::DEFINITIONS so ReadingSystem.definition can
    # hand one back without the callers learning a second shape. `work_id`
    # takes the place of `field`: this source is read through the dictionary
    # tables, not through character_properties.
    def definition(id)
      book = find(id)
      return nil unless book

      {
        label_key: nil,
        label: book[:label],
        source: [book[:title], book[:edition]].compact.join(" "),
        field: nil,
        work_id: book[:work_id],
        tone: :none,
        kind: :rime_book,
        script: :han,
        period: book[:period],
        year: book[:year],
        section_axis: book[:section_axis],
        facets: book[:facets]
      }
    end

    # The facet vocabularies for one book, read from that book's own sections.
    # { tones: [...], rhymes: [...] }
    def vocabulary(id)
      book = find(id)
      return { tones: [], rhymes: [] } unless book

      @vocabulary ||= {}
      @vocabulary[book[:id]] ||= {
        tones: section_values(book[:work_id], :tone),
        rhymes: section_values(book[:work_id], :rhyme_label)
      }
    end

    # --- internals --------------------------------------------------------

    def load_books
      rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
        SELECT dw.id            AS work_id,
               dw.title         AS title,
               dw.edition_label AS edition,
               COUNT(DISTINCT CASE WHEN ds.tone IS NOT NULL AND ds.tone <> ''
                                   THEN ds.tone END)         AS tone_count,
               COUNT(DISTINCT CASE WHEN ds.rhyme_label IS NOT NULL AND ds.rhyme_label <> ''
                                   THEN ds.rhyme_label END)  AS rhyme_count,
               SUM(CASE WHEN de.small_rime_number IS NOT NULL THEN 1 ELSE 0 END) AS small_rime_count
        FROM dictionary_works dw
        JOIN dictionary_entries de ON de.dictionary_work_id = dw.id
        LEFT JOIN dictionary_sections ds ON ds.id = de.dictionary_section_id
        GROUP BY dw.id, dw.title, dw.edition_label
      SQL

      fanqie = fanqie_counts

      rows.filter_map do |row|
        work_id = row["work_id"].to_i
        book = BOOKS[row["title"].to_s]
        next if book.nil?

        tones = row["tone_count"].to_i
        rhymes = row["rhyme_count"].to_i
        next if tones.zero? && rhymes.zero? && fanqie[work_id].to_i.zero?

        build_book(row, work_id, book, tones, rhymes, fanqie[work_id].to_i)
      end.sort_by { |book| [PERIOD_ORDER.index(book[:period]) || 99, book[:year], book[:title]] }
    end

    # The system a book records, when it says; otherwise its date decides, on
    # the boundaries cited above. Only the fallback consults the year.
    def period_for(year)
      return "old_chinese" if year < MIDDLE_CHINESE_FROM
      return "early_middle_chinese" if year < LATE_MIDDLE_CHINESE_FROM
      return "late_middle_chinese" if year <= MIDDLE_CHINESE_TO

      "early_mandarin"
    end

    def build_book(row, work_id, book, tones, rhymes, fanqie_count)
      year = book[:year]
      # A section axis is only 韻目 when the book actually sorts by rhyme.
      # 玉篇 is a 字書: its sections are 部首 (一部, 示部, 玉部), and calling
      # those rhyme categories would be the same class of error this module
      # exists to prevent.
      axis = tones.positive? ? :rhyme : :radical

      facets = []
      facets << :tone if tones.positive?
      facets << :rhyme_label if rhymes.positive?
      # small_rime_number counts entries within a section. In a 韻書 that
      # section is a rime and the number is the 小韻; in 玉篇 the section is a
      # radical and the number is just the entry's place in it, so offering it
      # as 小韻 would be a third misattribution of the same kind.
      facets << :small_rime if axis == :rhyme && row["small_rime_count"].to_i.positive?
      facets << :fanqie if fanqie_count.positive?

      {
        id: id_for(work_id),
        work_id: work_id,
        title: row["title"].to_s,
        edition: row["edition"].presence,
        label: [row["title"], row["edition"]].compact_blank.join("・"),
        period: book[:records].presence || period_for(year),
        year: year,
        section_axis: axis,
        facets: facets,
        fanqie_count: fanqie_count
      }
    end

    def fanqie_counts
      ActiveRecord::Base.connection.select_all(<<~SQL).to_a
        SELECT de.dictionary_work_id AS work_id, COUNT(*) AS n
        FROM dictionary_readings dr
        JOIN dictionary_entries de ON de.id = dr.dictionary_entry_id
        WHERE dr.kind = 'fanqie'
        GROUP BY de.dictionary_work_id
      SQL
        .to_h { |row| [row["work_id"].to_i, row["n"].to_i] }
    end

    # Ordered by the book's own sequence, so 廣韻 gives 上平聲 下平聲 上聲
    # 去聲 入聲 in 四聲 order and not alphabetically.
    # Only these two columns are ever addressable. The name goes into the SQL
    # text, so it is checked against a fixed list rather than trusted.
    SECTION_COLUMNS = %w[tone rhyme_label].freeze

    def section_values(work_id, column)
      column = column.to_s
      return [] unless SECTION_COLUMNS.include?(column)

      ActiveRecord::Base.connection.select_values(<<~SQL)
        SELECT value FROM (
          SELECT ds.#{column} AS value, MIN(ds.sequence_number) AS seq
          FROM dictionary_sections ds
          JOIN dictionary_entries de ON de.dictionary_section_id = ds.id
          WHERE de.dictionary_work_id = #{work_id.to_i}
            AND ds.#{column} IS NOT NULL AND ds.#{column} <> ''
          GROUP BY ds.#{column}
        ) ORDER BY seq
      SQL
    end
  end
end
