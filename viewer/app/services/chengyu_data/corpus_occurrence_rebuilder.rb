# frozen_string_literal: true

require "pathname"

module ChengyuData
  # Resolves structured Wiktionary provenance such as "derived from the
  # Analects" to the corpus' canonical work, then confirms the Chengyu by
  # finding its actual form in that work. The resulting table is derived data:
  # it can be rebuilt whenever either the Chengyu snapshot or corpus manifest
  # changes.
  class CorpusOccurrenceRebuilder
    Result = Struct.new(
      :occurrences,
      :provenance_groups,
      :mapped_groups,
      :unmapped_source_titles,
      keyword_init: true
    )

    SOURCE_TITLE_ALIASES = {
      "analects" => ["論語", "论语"],
      "bookofdocuments" => ["尚書", "尚书", "書經", "书经"],
      "bookofrites" => ["禮記", "礼记"],
      "classicofpoetry" => ["詩經", "诗经", "毛詩", "毛诗"],
      "hanfeizi" => ["韓非子", "韩非子"],
      "iching" => ["周易", "易經", "易经"],
      "mencius" => ["孟子", "孟子書", "孟子书"],
      "zhuangzi" => ["莊子", "庄子", "莊子書", "庄子书", "南華經", "南华经"],
      "zuozhuan" => ["春秋左氏傳", "春秋左氏传", "左傳", "左传"]
    }.freeze

    def initialize(root: Rails.configuration.x.corpus_root, manifest: nil)
      @root = Pathname(File.realpath(root.to_s))
      @manifest = manifest
      @body_cache = {}
    end

    def rebuild!
      manifest = @manifest || CorpusSearch::Manifest.new(root: @root.to_s).load_cached!
      documents = canonical_documents(manifest.documents)
      work_index = build_work_index(documents)

      provenances = ChengyuProvenance.includes(chengyu: :forms).order(:chengyu_id, :source_title, :id).to_a
      provenance_groups = provenances.group_by { |row| [row.chengyu_id, normalize_title(row.source_title)] }
      source_groups = provenance_groups.values
        .reject { |group| group.first.source_title.to_s.strip.blank? }
        .group_by { |group| normalize_title(group.first.source_title) }

      rows = []
      mapped_groups = 0
      unmapped_titles = []
      now = Time.current

      source_groups.each_value do |family_groups|
        source_title = family_groups.first.first.source_title.to_s.strip
        candidates = candidate_documents(work_index, source_title)
        if candidates.empty?
          unmapped_titles << source_title
          next
        end

        mapped_groups += family_groups.length
        representative_by_family = family_groups.to_h { |group| [group.first.chengyu_id, group.first] }
        forms = family_groups.flat_map { |group| group.first.chengyu.forms }.uniq(&:id)
        matcher = TextMatcher.new(forms: forms)

        candidates.each do |document|
          body = body_for(document.fetch("path"))
          matcher.matches(body).each do |match|
            representative = representative_by_family[match.chengyu_id]
            next unless representative

            rows << {
              chengyu_id: match.chengyu_id,
              chengyu_form_id: match.chengyu_form_id,
              chengyu_provenance_id: representative.id,
              corpus_work_id: document["work_id"].to_s.presence,
              corpus_document_id: document["id"].to_s.presence,
              document_path: document.fetch("path"),
              work_title: document["work"].to_s.presence || source_title,
              document_title: document["title"].to_s.presence,
              start_offset: match.start_offset,
              end_offset: match.end_offset,
              matched_text: match.matched_text,
              created_at: now,
              updated_at: now
            }
          end
        end
      end

      rows.uniq! { |row| [row[:chengyu_id], row[:document_path], row[:start_offset], row[:end_offset]] }

      ActiveRecord::Base.transaction do
        ChengyuCorpusOccurrence.delete_all
        rows.each_slice(1_000) { |slice| ChengyuCorpusOccurrence.insert_all!(slice) }
      end

      Result.new(
        occurrences: rows.length,
        provenance_groups: provenance_groups.length,
        mapped_groups: mapped_groups,
        unmapped_source_titles: unmapped_titles.uniq.sort
      )
    end

    private

    def canonical_documents(documents)
      Array(documents)
        .select { |doc| doc["searchable_body"] != false && CorpusSearch::DocumentRole.default?(doc["document_role"].presence || CorpusSearch::DocumentRole.classify(doc["path"])) }
        .group_by { |doc| doc["body_fingerprint"].presence || "path:#{doc['path']}" }
        .values
        .map { |duplicates| duplicates.min_by { |doc| document_rank(doc) } }
    end

    def document_rank(document)
      path = document["path"].to_s
      [
        document["work_id"].present? ? 0 : 1,
        path.include?("classical_wiki_corpus") ? 1 : 0,
        path,
      ]
    end

    def build_work_index(documents)
      documents.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |document, index|
        document_work_keys(document).each do |key|
          index[key] << document unless index[key].include?(document)
        end
      end
    end

    def document_work_keys(document)
      path = document["path"].to_s
      basename = File.basename(path, File.extname(path)).sub(/__.*/, "")
      folder = File.basename(document["folder_path"].to_s)
      [document["work"], folder, basename]
        .map { |value| normalize_title(value) }
        .reject(&:blank?)
        .uniq
    end

    def candidate_documents(work_index, source_title)
      keys = [source_title, *SOURCE_TITLE_ALIASES.fetch(normalize_title(source_title), [])]
        .map { |value| normalize_title(value) }
        .reject(&:blank?)
        .uniq

      documents = keys.flat_map { |key| work_index[key] }.uniq
      metadata_backed = documents.select { |document| document["work_id"].present? }
      documents = metadata_backed if metadata_backed.any?
      documents.sort_by { |doc| document_rank(doc) }
    end

    def normalize_title(value)
      value.to_s
        .unicode_normalize(:nfkc)
        .strip
        .downcase
        .sub(/\Athe\s+/, "")
        .gsub(/[《》〈〉「」『』“”‘’'"\s\p{P}\p{S}]/u, "")
    rescue Encoding::CompatibilityError
      value.to_s.strip.downcase.gsub(/\s+/, "")
    end

    def body_for(relative_path)
      @body_cache.fetch(relative_path) do
        absolute = @root.join(relative_path)
        raw = absolute.read(encoding: "UTF-8")
        @body_cache[relative_path] = CorpusSearch::DocumentReader.parse(raw).body.to_s
      end
    end
  end
end
