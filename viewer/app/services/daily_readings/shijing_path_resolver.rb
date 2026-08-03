# frozen_string_literal: true

require "json"
require "pathname"

module DailyReadings
  # Converts a DailyReading's stored literary-classification path into the
  # poem's current physical corpus path.
  #
  # Compilation folders can move while the Mao number remains stable. The
  # resolver therefore accepts an existing stored path, but repairs a stale one
  # by reading the Mao identifiers in the Shijing metadata sidecars.
  class ShijingPathResolver
    DEFAULT_SHIJING_ROOT_REL = "中國漢文/clean/周朝/東周/戰國時代/周/詩經"

    def initialize(corpus_root: Rails.configuration.x.corpus_root,
                   shijing_root_relative: DEFAULT_SHIJING_ROOT_REL,
                   logger: Rails.logger)
      @corpus_root = Pathname(File.realpath(corpus_root.to_s))
      @shijing_root_relative = normalize_relative(shijing_root_relative)
      raise ArgumentError, "Shijing root must be a safe relative path" unless @shijing_root_relative

      @shijing_root = absolute_path_for(@shijing_root_relative)
      @logger = logger
      @paths_by_mao = nil
    end

    # Returns a corpus-root-relative path suitable for corpus_viewer_path.
    def resolve(reading)
      stored_path = reading.respond_to?(:path) ? reading.path : nil
      mao_no = reading.respond_to?(:order_index) ? reading.order_index : nil
      resolve_values(stored_path: stored_path, mao_no: mao_no)
    end

    # The value-based form makes the path rule testable without Active Record.
    def resolve_values(stored_path:, mao_no:)
      stored_full_path = full_shijing_path(stored_path)
      return stored_full_path if existing_file?(stored_full_path)

      repaired_path = paths_by_mao[positive_integer(mao_no)]
      return repaired_path if existing_file?(repaired_path)

      # Keep the former diagnostic path if its metadata cannot be resolved.
      stored_full_path
    end

    private

    def paths_by_mao
      @paths_by_mao ||= build_path_index
    end

    def build_path_index
      index = {}
      return index unless @shijing_root&.directory?

      Dir.glob(@shijing_root.join("**", "metadata.json").to_s).sort.each do |metadata_path|
        index_metadata_file(index, metadata_path)
      rescue JSON::ParserError, SystemCallError, EncodingError => error
        log_warning("could not read #{metadata_path}: #{error.class}: #{error.message}")
      end

      index
    end

    def index_metadata_file(index, metadata_path)
      payload = JSON.parse(File.read(metadata_path, encoding: "bom|utf-8"))
      return unless payload.is_a?(Hash)

      document = canonical_document(payload, metadata_path)
      return unless document

      resolved_path = resolved_document_path(document, metadata_path)
      return unless existing_file?(resolved_path)
      return unless inside_shijing_root?(resolved_path)

      mao_numbers = identifier_values(document["identifiers"], "mao_no")
      mao_numbers = identifier_values(payload["identifiers"], "mao_no") if mao_numbers.empty?

      mao_numbers.each do |mao_no|
        previous = index[mao_no]
        if previous && previous != resolved_path
          log_warning("duplicate Mao number #{mao_no}: #{previous.inspect} and #{resolved_path.inspect}")
        else
          index[mao_no] = resolved_path
        end
      end
    end

    def canonical_document(payload, metadata_path)
      documents = document_records(payload).select { |document| text_document?(document) }
      return nil if documents.empty?

      title = payload["title"].to_s.strip
      expected_filename = title.end_with?(".txt") ? title : "#{title}.txt"

      documents.min_by do |document|
        filename = document_filename(document)
        [
          filename == expected_filename ? 0 : 1,
          filename.include?("_毛詩序") ? 1 : 0,
          filename.include?("_") ? 1 : 0,
          existing_document_path?(document, metadata_path) ? 0 : 1,
          filename
        ]
      end
    end

    def document_records(payload)
      records = Array(payload["documents"])

      Array(payload["editions"]).each do |edition|
        records += Array(edition["documents"]) if edition.is_a?(Hash)
      end

      Array(payload["translations"]).each do |translation|
        records += Array(translation["documents"]) if translation.is_a?(Hash)
      end

      records.select { |record| record.is_a?(Hash) }
    end

    def text_document?(document)
      document_filename(document).downcase.end_with?(".txt")
    end

    def document_filename(document)
      file = document["file"].to_s.strip
      return File.basename(file.tr("\\", "/")) unless file.empty?

      File.basename(document["path"].to_s.tr("\\", "/"))
    end

    def existing_document_path?(document, metadata_path)
      existing_file?(resolved_document_path(document, metadata_path))
    end

    def resolved_document_path(document, metadata_path)
      explicit = normalize_relative(document["path"])
      return explicit if existing_file?(explicit)

      file = document["file"].to_s.strip
      return nil if file.empty?

      absolute = Pathname(metadata_path).dirname.join(file).cleanpath
      return nil unless inside_corpus_root?(absolute)

      absolute.relative_path_from(@corpus_root).to_s.tr("\\", "/")
    rescue ArgumentError
      nil
    end

    def identifier_values(identifiers, scheme)
      Array(identifiers).filter_map do |identifier|
        next unless identifier.is_a?(Hash)
        next unless identifier["scheme"].to_s == scheme

        positive_integer(identifier["value"])
      end.uniq
    end

    def positive_integer(value)
      integer = Integer(value, exception: false)
      integer if integer&.positive?
    end

    def full_shijing_path(path)
      normalized = normalize_relative(path)
      return nil unless normalized

      if normalized == @shijing_root_relative || normalized.start_with?("#{@shijing_root_relative}/")
        normalized
      else
        File.join(@shijing_root_relative, normalized).tr("\\", "/")
      end
    end

    def inside_shijing_root?(path)
      path == @shijing_root_relative || path.start_with?("#{@shijing_root_relative}/")
    end

    def existing_file?(relative_path)
      absolute_path_for(relative_path)&.file? || false
    end

    def absolute_path_for(path)
      normalized = normalize_relative(path)
      return nil unless normalized

      absolute = @corpus_root.join(normalized).cleanpath
      inside_corpus_root?(absolute) ? absolute : nil
    end

    def normalize_relative(path)
      raw = path.to_s.strip.tr("\\", "/")
      return nil if raw.empty?

      pathname = Pathname(raw)
      return nil if pathname.absolute?

      normalized = pathname.cleanpath.to_s.tr("\\", "/")
      return nil if normalized == ".." || normalized.start_with?("../")

      normalized.sub(%r{\A\./}, "")
    end

    def inside_corpus_root?(absolute_path)
      absolute = absolute_path.expand_path.to_s
      root = @corpus_root.to_s
      absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
    end

    def log_warning(message)
      @logger&.warn("[DailyReadings::ShijingPathResolver] #{message}")
    end
  end
end
