# frozen_string_literal: true

module CharacterQuery
  # The picker's taxonomy: language family, then language or branch, then the
  # specific reading system or locality.
  #
  # Genetic family at the top, because "Wu" was never a unit a visitor could
  # pick and be done with — Wu speakers do not all follow Shanghainese, so the
  # locality is the real unit and the branch is only how you navigate to it.
  #
  # Jejueo and Okinawan (Uchinaaguchi) are siblings of Korean and Japanese
  # within Koreanic and Japonic, not varieties beneath them. That follows the
  # site's position, and the increasingly standard one since the mid-2010s.
  #
  # Localities are NOT hardcoded. They are enumerated from the existing
  # pronunciations i18n registry, so an import that ships its labels appears
  # here with no code change.
  module FamilyRegistry
    # 小學堂漢字古今音資料庫 — escaped so this file needs no encoding handling.
    XIAOXUETANG_SOURCE = "小學堂漢字古今音資料庫"

    FIELD_KEY = /\Areading_(?<branch>[a-z_]+)_(?<collection>[a-z]+)_(?<locality>\d+)_ipa\z/
    CONFIG_PATH = "config/character_query_families.yml"

    # branch (as it appears in character_properties) => interface locale code(s).
    # Not one-to-one: the database carries a single `pinghua` branch while the
    # locales split it north/south.
    BRANCH_LOCALES = {
      "mandarin" => %w[cmn], "jin" => %w[cjy], "wu" => %w[wuu], "hui" => %w[czh],
      "gan" => %w[gan], "hakka" => %w[hak], "min" => %w[nan], "xiang" => %w[hsn],
      "yue" => %w[yue], "pinghua" => %w[cnp csp], "other_sinitic" => []
    }.freeze

    SINITIC_BRANCHES = BRANCH_LOCALES.keys.freeze

    # family -> branches. A branch may carry `systems` (named reading systems,
    # listed first), `localities` (the 小學堂 branch key), or both. Where a
    # branch has exactly one system and no localities the third dropdown is
    # redundant and the interface hides it.
    TAXONOMY = [
      {
        key: "sino_tibetan",
        branches: [
          { key: "mandarin", systems: %w[mandarin], localities: "mandarin" },
          { key: "jin", localities: "jin" },
          { key: "wu", localities: "wu" },
          { key: "hui", localities: "hui" },
          { key: "gan", localities: "gan" },
          { key: "hakka", localities: "hakka" },
          { key: "min", localities: "min" },
          { key: "xiang", localities: "xiang" },
          { key: "yue", systems: %w[cantonese], localities: "yue" },
          { key: "pinghua", localities: "pinghua" },
          { key: "other_sinitic", localities: "other_sinitic" },
          # Historical Sinitic, split by period.
          #
          # This was one "historical" branch holding everything from 上古 to
          # 老國音, which put a Baxter & Sagart reconstruction, a Yuan
          # rime book and a 1913 standard in one dropdown as peers. They are
          # not peers, and the flattening is what let a Ming book's tone
          # categories be applied to a Middle Chinese search.
          #
          # Each period lists reconstructions first and the corpus's own
          # attested books after, and the interface groups them under separate
          # headings, because a reconstruction and a rime book are different
          # kinds of claim: 廣韻 records 徳紅切; Baxter, Pulleyblank and
          # Karlgren each say what they think that spelling sounded like.
          { key: "old_chinese", systems: %w[old_chinese_bs2014],
            rime_period: "old_chinese" },
          # Baxter & Sagart's Middle Chinese is a transcription of the 切韻
          # system, so it belongs with Early Middle Chinese and not with the
          # Song books that are dated to the later period.
          { key: "early_middle_chinese",
            systems: %w[middle_chinese_bs2014 middle_chinese_bs2006],
            rime_period: "early_middle_chinese" },
          { key: "late_middle_chinese", rime_period: "late_middle_chinese" },
          # 中原音韻 1324 and 蒙古字韻 1269 are Old Mandarin; 洪武正韻 1375
          # joins them by date. See RimeBooks::PERIODS for the caveat on it.
          { key: "early_mandarin", systems: %w[zhongyuan menggu_ziyun],
            rime_period: "early_mandarin" },
          # Neither historical nor a topolect: 通字 is a constructed
          # diasystem and 老國音 a superseded national standard.
          { key: "constructed", systems: %w[general_chinese laoguoyin] }
        ]
      },
      { key: "japonic",
        branches: [
          { key: "japanese", systems: %w[japanese_on] },
          { key: "okinawan", systems: %w[okinawan_shuri] }
        ] },
      { key: "koreanic",
        branches: [
          { key: "korean", systems: %w[korean_hangul] },
          { key: "jejueo", systems: %w[jejueo] }
        ] },
      { key: "austroasiatic", branches: [{ key: "vietnamese", systems: %w[vietnamese] }] },
      { key: "kra_dai", branches: [{ key: "zhuang", systems: %w[zhuang] }] }
    ].freeze

    module_function

    def branches
      SINITIC_BRANCHES
    end

    def locales_for(branch)
      BRANCH_LOCALES.fetch(branch.to_s, [])
    end

    def config
      @config ||= begin
        path = Rails.root.join(CONFIG_PATH)
        path.exist? ? (YAML.safe_load(path.read) || {}) : {}
      rescue StandardError
        {}
      end
    end

    def reset!
      @config = nil
      @localities = nil
      @topolect_index = nil
      RimeBooks.reset!
    end

    # { "yue" => [{ locality:, label:, field:, system_id: }, ...] }
    def localities
      @localities ||= begin
        fields = safe_translation("pronunciations.fields")
        labels = safe_translation("pronunciations.ruby_sources")

        grouped = Hash.new { |hash, key| hash[key] = [] }
        fields.each_key do |key|
          match = FIELD_KEY.match(key.to_s)
          next unless match

          collection = match[:collection]
          locality = match[:locality]
          entry = labels[:"#{collection}_#{locality}"] || labels["#{collection}_#{locality}"]

          grouped[match[:branch]] << {
            branch: match[:branch], collection: collection, locality: locality,
            label: extract_label(entry) || "#{collection}_#{locality}",
            field: "reading.#{match[:branch]}.#{collection}_#{locality}.ipa",
            system_id: system_id_for(match[:branch], collection, locality)
          }
        end

        grouped.each_value { |list| list.sort_by! { |entry| entry[:locality].to_i } }
        grouped
      end
    end

    def localities_for(branch)
      localities[branch.to_s] || []
    end

    def system_id_for(branch, collection, locality)
      "topolect:#{branch}:#{collection}_#{locality}"
    end

    def topolect_system_ids
      localities.values.flatten.map { |entry| entry[:system_id] }
    end

    def topolect_definition(id)
      return nil unless id.to_s.start_with?("topolect:")

      entry = topolect_index[id.to_s]
      return nil unless entry

      { label_key: nil, label: entry[:label], source: XIAOXUETANG_SOURCE,
        field: entry[:field], tone: :superscript_digit, kind: :topolect,
        script: :ipa, branch: entry[:branch] }
    end

    def topolect_index
      @topolect_index ||= localities.values.flatten.index_by { |entry| entry[:system_id] }
    end

    # === picker tree ======================================================

    def family_keys
      TAXONOMY.map { |family| family[:key] }
    end

    # Branches that actually have something to offer, for one family.
    def branches_for(family_key)
      family = TAXONOMY.find { |entry| entry[:key] == family_key.to_s }
      return [] unless family

      family[:branches].filter_map do |branch|
        systems = Array(branch[:systems]).select { |id| ReadingSystem.queryable?(id) }
        locality_entries = branch[:localities] ? localities_for(branch[:localities]) : []
        rime_entries = branch[:rime_period] ? RimeBooks.for_period(branch[:rime_period]) : []
        next if systems.empty? && locality_entries.empty? && rime_entries.empty?

        {
          key: branch[:key],
          systems: systems,
          locality_branch: branch[:localities],
          locality_count: locality_entries.size,
          rime_period: branch[:rime_period],
          rime_count: rime_entries.size,
          # One system and nothing else: the third dropdown would hold a
          # single option, so the interface skips it.
          single_system: (systems.size == 1 && locality_entries.empty? && rime_entries.empty?) ? systems.first : nil
        }
      end
    end

    # Third-dropdown contents for one branch: named systems first, then the
    # commonly consulted localities, then the rest.
    def options_for_branch(family_key, branch_key)
      branch = branches_for(family_key).find { |entry| entry[:key] == branch_key.to_s }
      return { "named" => [], "rime_books" => [], "common" => [], "all" => [] } unless branch

      locality_branch = branch[:locality_branch]
      entries = locality_branch ? localities_for(locality_branch) : []
      references = locality_branch ? reference_varieties(locality_branch) : []

      rime_entries = branch[:rime_period] ? RimeBooks.for_period(branch[:rime_period]) : []

      {
        "named" => branch[:systems].map do |id|
          [ReadingSystem.label_for(id), id,
           I18n.t("character_query.system_hints.#{id}", default: "")]
        end,
        # Attested books, kept in their own group so the interface can head
        # them separately from the reconstructions above.
        "rime_books" => rime_entries.map do |book|
          ["#{book[:label]} (#{book[:year]})", book[:id],
           I18n.t("character_query.rime_book_hints.#{book[:title]}", default: "")]
        end,
        "common" => references.map { |entry| [entry[:label], entry[:system_id], ""] },
        "all" => entries.sort_by { |entry| entry[:label].to_s }
                        .map { |entry| [entry[:label], entry[:system_id], ""] }
      }
    end

    # === reference varieties ==============================================
    #
    # Promoted by a stated administrative rule (see the config file). Allowed
    # to return nothing, and when it does the interface simply shows the full
    # list — a visitor is never told about a heuristic that found nothing.
    def reference_varieties(branch)
      family = config.dig("families", branch.to_s) || {}
      suppressed = Array(family["suppress"]).map { |value| normalise_locality(value) }

      # Locality ids are zero-padded to three digits in the pronunciation
      # registry (xiaoxuetang_027). Compare on a normalised key so a config
      # entry written as "27" still resolves — getting this wrong silently
      # dropped every promoted locality below 100.
      by_locality = localities_for(branch).index_by { |entry| normalise_locality(entry[:locality]) }

      Array(family["promote"]).filter_map do |item|
        locality = normalise_locality(item["locality"])
        next if suppressed.include?(locality)

        entry = by_locality[locality]
        next unless entry

        entry.merge(basis: item["basis"].to_s,
                    basis_kind: item["basis_kind"].to_s.presence || "administrative_seat",
                    note: item["note"].to_s.presence)
      end
    end

    def reference_varieties_absent?(branch)
      localities_for(branch).any? && reference_varieties(branch).empty?
    end

    def absence_reason(branch)
      config.dig("families", branch.to_s, "absence_reason").to_s.presence
    end

    # === helpers ==========================================================

    # Strips leading zeros so "027" and "27" are the same locality, without
    # turning "0" into "".
    def normalise_locality(value)
      value.to_s.strip.sub(/\A0+(?=\d)/, "")
    end

    # Registry labels carry a reading-type suffix ("Guangzhou - IPA"). Useful
    # in a flat pronunciation list, redundant here.
    def extract_label(entry)
      raw =
        case entry
        when Hash then (entry[:label] || entry["label"]).to_s
        when String then entry.to_s
        else ""
        end

      raw.sub(/\s*[—–-]\s*IPA\s*\z/, "").strip.presence
    end

    def safe_translation(key)
      value = I18n.t(key, default: {})
      value.is_a?(Hash) ? value : {}
    end
  end
end
