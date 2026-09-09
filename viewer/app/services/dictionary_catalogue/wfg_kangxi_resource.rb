# frozen_string_literal: true

require "base64"
require "digest"
require "sqlite3"
require "thread"

module DictionaryCatalogue
  # Read-only access to the reviewed WFG Kangxi extraction bundled with Fanya.
  # The SQLite resource keeps 47,043 occurrence records and the original MDD
  # image bytes together without creating tens of thousands of repository files.
  class WfgKangxiResource
    PATH = "resources/kangxi/wfg_kangxi.sqlite3"
    SHA256 = "a118dae8e4efc50b36f63690667977d826c49e433ce3375f0604cfd65e69d2e7"
    EXPECTED = {
      "occurrence_count" => "47043",
      "primary_record_count" => "46976",
      "redirect_count" => "247",
      "resource_count" => "47853"
    }.freeze

    class << self
      def path
        Rails.root.join(PATH)
      end

      def available?
        current = path
        return false unless current.file? && current.size.positive?

        stamp = [current.mtime.to_f, current.size].freeze
        return @availability.fetch(:value) if @availability && @availability.fetch(:stamp) == stamp

        valid = Digest::SHA256.file(current).hexdigest == SHA256
        if valid
          metadata = metadata_hash
          valid &&= EXPECTED.all? { |key, expected| metadata[key] == expected }
        end

        @availability = { stamp: stamp, value: valid }.freeze
        valid
      rescue SQLite3::Exception, Errno::ENOENT
        false
      end

      def metadata_hash
        rows = query("SELECT key, value FROM metadata")
        rows.to_h { |row| [row.fetch("key"), row.fetch("value")] }
      end

      def occurrence(serial)
        query_one("SELECT * FROM occurrences WHERE serial = ?", Integer(serial))
      rescue ArgumentError, TypeError
        nil
      end

      def image_data_uri(key)
        value = key.to_s
        return nil if value.empty?

        row = query_one("SELECT mime, bytes FROM resources WHERE key = ?", value)
        return nil unless row

        "data:#{row.fetch('mime')};base64,#{Base64.strict_encode64(row.fetch('bytes'))}"
      end

      def resource_exists?(key)
        !query_one("SELECT key FROM resources WHERE key = ?", key.to_s).nil?
      end

      def query(sql, *binds)
        mutex.synchronize do
          connection.execute(sql, binds).map { |row| stringify_row(row) }
        end
      end

      def query_one(sql, *binds)
        query(sql, *binds).first
      end

      def reset!
        mutex.synchronize do
          @db&.close
          @db = nil
          @db_stamp = nil
          @availability = nil
        end
      rescue SQLite3::Exception
        @db = nil
        @db_stamp = nil
        @availability = nil
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end

      def connection
        current = path
        stamp = [current.mtime.to_f, current.size].freeze
        if @db.nil? || @db_stamp != stamp
          @db&.close
          @db = SQLite3::Database.new(current.to_s, readonly: true)
          @db.results_as_hash = true
          @db.busy_timeout = 2_000
          @db_stamp = stamp
        end
        @db
      end

      def stringify_row(row)
        row.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value unless key.is_a?(Integer)
        end
      end
    end
  end
end
