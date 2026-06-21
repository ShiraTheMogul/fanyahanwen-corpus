require "json"
require "fileutils"
require "time"

  # frozen_string_literal: true

  class CorpusAnnotationsStore
    KINDS = %w[title person place office ambiguous_character].freeze

    def initialize(root:, rel_text_path:)
      @fs = CorpusFs.new(root: root)
      @rel_text_path = rel_text_path.to_s
      @abs_text_path = @fs.resolve(@rel_text_path)
      @abs_json_path = annotation_path_for(@abs_text_path)
    end

    def read
      raw = File.read(@abs_json_path, mode: "r:BOM|UTF-8", invalid: :replace, undef: :replace, replace: "")
      data = JSON.parse(raw)
      data.is_a?(Hash) ? data : { "version" => 1, "items" => [] }
    end

    def write(data)
      raise ArgumentError, "Annotation payload must be a Hash" unless data.is_a?(Hash)

      payload = {
        "version" => (data["version"].to_i <= 0 ? 1 : data["version"].to_i),
        "items" => Array(data["items"]),
        "updated_at" => Time.now.utc.iso8601
      }

      dir = File.dirname(@abs_json_path)
      FileUtils.mkdir_p(dir)

      tmp = @abs_json_path + ".tmp"
      File.write(tmp, JSON.pretty_generate(payload) + "
", mode: "w:UTF-8")
      FileUtils.mv(tmp, @abs_json_path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    private

    def annotation_path_for(abs_text_path)
      abs_text_path.to_s + ".annotations.json"
    end
  end
