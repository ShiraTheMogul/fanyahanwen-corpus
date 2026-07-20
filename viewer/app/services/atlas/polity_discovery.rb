# frozen_string_literal: true

require "set"

module Atlas
  # Discovers represented polities from the prepared corpus manifest.
  #
  # Existing human-written Atlas entries remain authoritative. Discovery only
  # fills gaps so that a polity represented by corpus metadata or by an
  # explicitly configured polity-folder layer cannot disappear from a period
  # page merely because no Atlas article has been written yet.
  class PolityDiscovery
    GENERIC_CHILD_FOLDERS = Set.new(%w[
      原不詳 未分類 不詳 其他 其它 雜項
      金文 簡牘 石刻 碑刻 翻譯 注釋 註釋
      raw clean variants variant kanbun hanmun hanvan
    ]).freeze

    Result = Struct.new(:entries, :generated_count, :folder_discovered_count, keyword_init: true)

    def initialize(periodisation: Periodisation.default)
      @periodisation = periodisation
    end

    def merge(source_entries:, documents:, directory_paths: [])
      source_entries = Array(source_entries).map { |row| deep_dup(row) }
      documents = Array(documents)
      candidates, claimed_documents = folder_candidates(
        documents,
        directory_paths: Array(directory_paths)
      )
      metadata_candidates(documents, claimed_documents: claimed_documents).each do |key, candidate|
        merge_candidate!(candidates, key, candidate)
      end

      existing_by_key = source_entries.each_with_object({}) do |row, index|
        key = source_key(row)
        index[key] = row if key
      end

      generated_count = 0
      folder_discovered_count = 0
      candidates.each do |key, candidate|
        if (existing = existing_by_key[key])
          merge_into_source!(existing, candidate)
        else
          source_entries << synthetic_source(candidate)
          generated_count += 1
          folder_discovered_count += 1 if candidate[:folder_discovered]
        end
      end

      Result.new(
        entries: source_entries,
        generated_count: generated_count,
        folder_discovered_count: folder_discovered_count
      )
    end

    private

    def folder_candidates(documents, directory_paths:)
      candidates = {}
      claimed_documents = Set.new

      @periodisation.periods.each do |period|
        mode = period["polity_discovery"].to_s
        next if mode.blank? || mode == "none"

        region = period.fetch("macro_region")
        period_id = period.fetch("id")
        period_chain = (@periodisation.ancestors_for(region, period_id) + [period]).map { |row| row.fetch("id") }
        excluded = GENERIC_CHILD_FOLDERS | Set.new(Array(period["excluded_polity_folders"]).map(&:to_s))

        Array(period["corpus_paths"]).each do |prefix|
          root = prefix.to_s.split("/").first.to_s
          next if root.blank?

          directory_paths.each do |directory_path|
            child = immediate_child(directory_path, prefix)
            next if child.blank? || excluded_child?(child, excluded)
            next unless child_allowed?(child, mode: mode, period: period)

            key = [root, child]
            candidate = (candidates[key] ||= blank_candidate(
              root: root,
              polity: child,
              macro_region: region,
              folder_discovered: true
            ))
            candidate[:paths] << [prefix, child].join("/")
            candidate[:period_ids].merge(period_chain)
          end
        end
      end

      # Tie manifest rows to folder-discovered entries for statistics and prevent
      # stale broad metadata values from creating duplicate entries. Index the
      # candidate paths first: walking each document's few ancestor paths is
      # bounded, unlike comparing every document with every candidate polity.
      candidates_by_path = Hash.new { |hash, key| hash[key] = [] }
      candidates.each do |candidate_key, candidate|
        candidate[:paths].each { |path| candidates_by_path[path] << candidate_key }
      end

      documents.each do |document|
        matched_keys = Set.new
        [document["folder_path"], document["path"]].map(&:to_s).reject(&:blank?).each do |path|
          ancestor_paths(path).each do |ancestor|
            Array(candidates_by_path[ancestor]).each { |candidate_key| matched_keys << candidate_key }
          end
        end
        next if matched_keys.empty?

        identity = document_identity(document)
        matched_keys.each { |candidate_key| candidates.fetch(candidate_key)[:document_ids] << identity }
        claimed_documents << identity
      end

      [candidates, claimed_documents]
    end

    def metadata_candidates(documents, claimed_documents:)
      candidates = {}

      documents.each do |document|
        root = document["corpus_root"].to_s.strip
        polity = document["polity"].to_s.strip
        next if root.blank? || polity.blank? || @periodisation.excluded_corpus_root?(root)

        # An explicitly configured folder layer is more trustworthy than stale
        # work-level polity metadata. This prevents, for example, every Edo
        # domain from collapsing back into the broad polity value 日本.
        next if claimed_documents.include?(document_identity(document))

        region = @periodisation.normalise_macro_region(
          document["macro_region"],
          corpus_root: root
        ).to_s
        next if region.blank?

        inferred_paths = inferred_paths_for(document, region: region, polity: polity)
        # A metadata value may be stale or copied from another context. New
        # Atlas entries require structural support from a typed corpus path;
        # metadata still enriches any existing human source entry later.
        next if inferred_paths.empty?

        key = [root, polity]
        candidate = (candidates[key] ||= blank_candidate(
          root: root,
          polity: polity,
          macro_region: region,
          folder_discovered: false
        ))
        candidate[:period_ids].merge(@periodisation.period_ids_for_document(document))
        candidate[:document_ids] << document_identity(document)
        candidate[:paths].merge(inferred_paths)
      end

      candidates
    end

    def inferred_paths_for(document, region:, polity:)
      paths = Set.new
      @periodisation.period_ids_for_document(document).each do |period_id|
        period = @periodisation.period(region, period_id)
        next unless period

        Array(period["corpus_paths"]).each do |prefix|
          candidate = best_document_path(document)
          next unless path_within?(candidate, prefix)

          child = immediate_child(candidate, prefix)
          if child == polity
            paths << [prefix, child].join("/")
          elsif child.blank?
            paths << prefix
          end
        end
      end
      paths
    end

    def merge_candidate!(candidates, key, candidate)
      current = candidates[key]
      unless current
        candidates[key] = candidate
        return
      end

      current[:paths].merge(candidate[:paths])
      current[:period_ids].merge(candidate[:period_ids])
      current[:document_ids].merge(candidate[:document_ids])
      current[:folder_discovered] ||= candidate[:folder_discovered]
    end

    def merge_into_source!(source, candidate)
      corpus = stringify_keys(source["corpus"].to_h)
      atlas = stringify_keys(source["atlas"].to_h)
      corpus["paths"] = (Array(corpus["paths"]) + candidate[:paths].to_a).map(&:to_s).reject(&:blank?).uniq
      atlas["period_ids"] = (Array(atlas["period_ids"]) + candidate[:period_ids].to_a).map(&:to_s).reject(&:blank?).uniq
      source["corpus"] = corpus
      source["atlas"] = atlas
      source
    end

    def synthetic_source(candidate)
      polity = candidate.fetch(:polity)
      region = candidate.fetch(:macro_region)
      {
        "id" => "#{region}--#{polity}",
        "kind" => "polity",
        "name" => {
          "display" => polity,
          "hanzi" => polity,
          "alt" => []
        },
        "timespan" => {
          "start_year" => nil,
          "end_year" => nil,
          "ongoing" => false,
          "start_approx" => false,
          "end_approx" => false
        },
        "locations" => { "capital" => [], "territory_note" => "" },
        "notable_authors" => [],
        "notable_works" => [],
        "related" => [],
        "corpus" => {
          "root" => candidate.fetch(:root),
          "periods" => [],
          "polity" => polity,
          "paths" => candidate[:paths].to_a.sort
        },
        "atlas" => {
          "period_ids" => candidate[:period_ids].to_a,
          "generated_from_manifest" => true,
          "folder_discovered" => candidate[:folder_discovered] == true
        },
        "article_path" => "entries/#{polity}/index.md",
        "published" => false,
        "notes" => ""
      }
    end

    def blank_candidate(root:, polity:, macro_region:, folder_discovered:)
      {
        root: root,
        polity: polity,
        macro_region: macro_region,
        paths: Set.new,
        period_ids: Set.new,
        document_ids: Set.new,
        folder_discovered: folder_discovered
      }
    end

    def source_key(row)
      corpus = stringify_keys(row["corpus"].to_h)
      root = corpus["root"].to_s.strip
      polity = corpus["polity"].to_s.strip
      return nil if root.blank? || polity.blank?

      [root, polity]
    end

    def child_allowed?(child, mode:, period:)
      explicit = Array(period["included_polity_folders"]).map(&:to_s)
      return true if explicit.include?(child)

      case mode
      when "all_children"
        true
      when "political_names"
        political_name?(child)
      else
        false
      end
    end

    def political_name?(name)
      name.match?(/(?:國|国|藩|朝|帝國|帝国|共和國|共和国|王國|王国|一揆|惣|中惣)\z/) ||
        %w[北朝 南朝 倭 日本 蝦夷島].include?(name)
    end

    def excluded_child?(child, excluded)
      excluded.include?(child) ||
        child.match?(/(?:金文|簡牘|简牍|古墳群|古坟群)\z/) ||
        child.start_with?("未分類", "原不詳")
    end

    def immediate_child(candidate, prefix)
      candidate = candidate.to_s
      prefix = prefix.to_s.sub(%r{/+\z}, "")
      return nil unless path_within?(candidate, prefix)

      remainder = candidate.delete_prefix(prefix).sub(%r{\A/+}, "")
      remainder.split("/").first.to_s.presence
    end

    def ancestor_paths(path)
      parts = path.to_s.tr("\\", "/").split("/").reject(&:empty?)
      parts.length.downto(1).map { |length| parts.first(length).join("/") }
    end

    def best_document_path(document)
      document["folder_path"].to_s.presence || document["path"].to_s
    end

    def document_identity(document)
      document["id"].to_s.presence || [document["path"], document["folder_path"]].join("\u0000")
    end

    def path_within?(candidate, prefix)
      candidate = candidate.to_s
      prefix = prefix.to_s
      candidate == prefix || candidate.start_with?(prefix + "/")
    end

    def stringify_keys(value)
      Grammar::MarkdownDocument.stringify_keys(value)
    end

    def deep_dup(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
