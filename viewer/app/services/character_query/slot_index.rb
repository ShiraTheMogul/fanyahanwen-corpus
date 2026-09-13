# frozen_string_literal: true

require "zlib"
require "json"
require "digest"

module CharacterQuery
  # Slot -> codepoint-id index, cached on disk per reading system.
  #
  # Why this exists: the forward query ("give me every character in slot X")
  # cannot be expressed as an indexed lookup. Values in character_properties
  # are whole reading strings — "yī", "xíng,xìng", "i³⁵" — so the slot is only
  # visible after normalisation in Ruby. Reading the 44,348 kMandarin rows
  # takes ~8s on the production machine, which is fine once and unacceptable
  # per request.
  #
  # Follows the storage pattern already used by CorpusSearch::CacheStore:
  # gzip'd JSON under storage/, written atomically. Deliberately NOT a
  # migration — no schema change, and nothing to rebuild on a 2.2GB table.
  #
  # The index is built lazily on first use and self-heals when the underlying
  # row count changes, so there is no rake task to remember. One is provided
  # for pre-warming only.
  module SlotIndex
    # Bump this whenever ReadingSystem changes how a reading is split, not
    # only when the file format changes.
    #
    # The cache self-heals when the underlying row count changes, which covers
    # a re-import but is blind to a normalisation change: the same rows now
    # produce different slots, the count is identical, and a stale index is
    # served indefinitely.
    #
    # Version 3 was the Middle Chinese tone split — dangX became dang + 上聲,
    # which took Middle Chinese from 2,413 slots to 1,540 without touching a
    # row. Version 4 chased the Old Chinese suffix boundary; version 5 undoes
    # that entirely, because Old Chinese had no tones and *-s is derivational
    # morphology rather than a tone marker. See ReadingSystem's notes.
    FORMAT_VERSION = 5
    CACHE_DIR = "storage/character_query"

    class Unsupported < StandardError; end

    # Systems backed by a dedicated table rather than character_properties.
    TABLE_MODELS = { laoguoyin: "LaoguoyinReading" }.freeze

    module_function

    # { slot => { all: [ids], tones: { 1 => [ids] } } }
    def for(system_id)
      definition = ReadingSystem.definition(system_id)
      raise Unsupported, "unknown reading system #{system_id.inspect}" if definition.nil?
      raise Unsupported, "#{system_id} has no readable source" if definition[:field].blank? && definition[:table].blank?

      cached = read_cache(system_id)
      return cached[:slots] if cached && cached[:row_count] == row_count(definition)

      built = build(system_id, definition)
      write_cache(system_id, built)
      built[:slots]
    end

    def slots(system_id)
      self.for(system_id).keys.sort
    end

    # Codepoint ids for one slot. `tone` nil means tone-blind.
    #
    # The ü fallback exists because "v" is accepted as ASCII ü on input. "lv"
    # becomes lü, which is a real slot and resolves directly. "jv" becomes jü,
    # which is not — standard pinyin writes ju, since the ü is implied after
    # j/q/x/y. So a ü slot that does not exist is retried with plain u. This
    # never mis-resolves lv or nv, because lü and nü do exist and the fallback
    # is not reached.
    def codepoint_ids(system_id:, slot:, tone: nil)
      index = self.for(system_id)
      key = slot.to_s
      entry = index[key]

      if entry.nil? && key.include?("\u00FC")
        entry = index[key.tr("\u00FC", "u")]
      end

      return [] if entry.nil?
      return Array(entry["all"] || entry[:all]) if tone.nil?

      tones = entry["tones"] || entry[:tones] || {}
      Array(tones[tone.to_s] || tones[tone])
    end

    # Coverage figures for a system, for the per-column reporting the
    # comparison view needs. A sparse locality must not read as a tight
    # constraint, so this is surfaced in the UI rather than kept internal.
    # Slots in this system closest to one that returned nothing, with how many
    # characters each holds.
    #
    # The case this exists for: Xiaoxuetang writes the Shanghai voiced onset
    # as zɦ, so zɿ — which is how most other Wu localities in the same source
    # write it — matches nothing at all there, while zɦɿ holds 92 characters
    # including 是. Without this the tool answers "nothing matches" and the
    # reader cannot tell a spelling difference from a real absence.
    #
    # Ranked by the longest shared run of characters, then by how close the
    # lengths are, then by size. Cheap: a few hundred slots already in memory,
    # no database work, and only ever run when a query came back empty.
    def nearest_slots(system_id, slot, limit: 5)
      wanted = slot.to_s
      return [] if wanted.empty?

      index = self.for(system_id)
      floor = wanted.length > 1 ? 2 : 1

      scored = index.filter_map do |candidate, entry|
        overlap = shared_subsequence(wanted, candidate)
        next if overlap < floor

        [candidate, Array(entry["all"] || entry[:all]).size, overlap]
      end

      scored.sort_by { |candidate, count, overlap| [-overlap, (candidate.length - wanted.length).abs, -count] }
            .first(limit)
            .map { |candidate, count, _| { slot: candidate, count: count } }
    rescue Unsupported
      []
    end

    # Longest common SUBSEQUENCE, not substring.
    #
    # The difference is the whole point. Xiaoxuetang writes Shanghai's voiced
    # onset zɦ where most of Wu writes z, so zɿ and zɦɿ share no run longer
    # than a single character — a substring measure scores them 1 and throws
    # the only useful suggestion away. As a subsequence they share both
    # characters, which is what a reader means by "nearly the same".
    def shared_subsequence(left, right)
      table = Array.new(right.length + 1, 0)

      left.each_char do |lchar|
        diagonal = 0
        right.each_char.with_index do |rchar, j|
          above = table[j + 1]
          table[j + 1] = lchar == rchar ? diagonal + 1 : [table[j], table[j + 1]].max
          diagonal = above
        end
      end

      table.last
    end

    def coverage(system_id)
      index = self.for(system_id)
      ids = index.each_value.flat_map { |entry| Array(entry["all"] || entry[:all]) }.uniq
      { slot_count: index.size, character_count: ids.size }
    end

    def build(system_id, definition)
      return build_from_table(system_id, definition) if definition[:table].present?

      slots = {}
      scope = CharacterProperty.where(source: definition[:source], field: definition[:field])

      # `pluck` in batches, not `find_each`: find_each walks a cursor over the
      # primary key and rejects a relation whose select omits it, and there is
      # no reason to instantiate 44,348 ActiveRecord objects to read two
      # columns. in_batches adds its own id ordering, so no custom select.
      scope.in_batches(of: 10_000) do |batch|
        batch.pluck(:character_codepoint_id, :value).each do |codepoint_id, value|
          ReadingSystem.readings_in(value, system_id).each do |reading|
            slot, tone = ReadingSystem.split(reading, system_id)
            next if slot.blank?

            bucket = (slots[slot] ||= { "all" => [], "tones" => {} })
            bucket["all"] << codepoint_id
            next if tone.nil?

            (bucket["tones"][tone.to_s] ||= []) << codepoint_id
          end
        end
      end

      slots.each_value do |bucket|
        bucket["all"].uniq!
        bucket["tones"].each_value(&:uniq!)
      end

      { slots: slots, row_count: row_count(definition), built_at: Time.current.iso8601 }
    end

    # Some systems live in their own table rather than in the EAV store —
    # laoguoyin_readings is the one at present. Same output shape, so nothing
    # downstream needs to know the difference.
    def build_from_table(system_id, definition)
      slots = {}
      model = TABLE_MODELS.fetch(definition[:table]).constantize
      column = definition[:column]

      model.in_batches(of: 10_000) do |batch|
        batch.pluck(:character_codepoint_id, column).each do |codepoint_id, value|
          ReadingSystem.readings_in(value, system_id).each do |reading|
            slot, tone = ReadingSystem.split(reading, system_id)
            next if slot.blank?

            bucket = (slots[slot] ||= { "all" => [], "tones" => {} })
            bucket["all"] << codepoint_id
            next if tone.nil?

            (bucket["tones"][tone.to_s] ||= []) << codepoint_id
          end
        end
      end

      slots.each_value do |bucket|
        bucket["all"].uniq!
        bucket["tones"].each_value(&:uniq!)
      end

      { slots: slots, row_count: row_count(definition), built_at: Time.current.iso8601 }
    end

    def row_count(definition)
      return TABLE_MODELS.fetch(definition[:table]).constantize.count if definition[:table].present?

      # Uses the (source, field, value) index from its leading column, so this
      # stays a bounded index scan.
      CharacterProperty.where(source: definition[:source], field: definition[:field]).count
    end

    # -- cache -------------------------------------------------------------

    def cache_path(system_id)
      digest = Digest::SHA256.hexdigest(system_id.to_s)[0, 16]
      Rails.root.join(CACHE_DIR, "slots-v#{FORMAT_VERSION}-#{digest}.json.gz")
    end

    def read_cache(system_id)
      path = cache_path(system_id)
      return nil unless path.exist?

      payload = JSON.parse(Zlib::GzipReader.open(path, &:read))
      return nil unless payload["format_version"] == FORMAT_VERSION

      { slots: payload["slots"], row_count: payload["row_count"], built_at: payload["built_at"] }
    rescue StandardError
      # A truncated or unreadable cache is a rebuild, never an error the user
      # has to see.
      nil
    end

    def write_cache(system_id, built)
      path = cache_path(system_id)
      FileUtils.mkdir_p(path.dirname)
      temp = path.sub_ext(".#{Process.pid}.tmp")

      Zlib::GzipWriter.open(temp) do |gz|
        gz.write(JSON.generate(
                   format_version: FORMAT_VERSION,
                   system: system_id.to_s,
                   row_count: built[:row_count],
                   built_at: built[:built_at],
                   slots: built[:slots]
                 ))
      end

      File.rename(temp, path)
      path
    rescue StandardError
      FileUtils.rm_f(temp) if defined?(temp) && temp
      nil
    end

    def clear!(system_id = nil)
      if system_id
        FileUtils.rm_f(cache_path(system_id))
      else
        FileUtils.rm_rf(Rails.root.join(CACHE_DIR))
      end
    end
  end
end
