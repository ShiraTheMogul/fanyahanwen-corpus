require "yaml"

module Textbook
  class LessonStore
    BASE_DIR = Rails.root.join("config", "textbook", "lessons")

    class << self

      # Parse YAML safely for editor UI (never raises).
      def safe_parse_yaml(yaml_str)
        begin
          parsed = YAML.safe_load(yaml_str.to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue
          {}
        end
      end

      def all
        Dir.glob(BASE_DIR.join("*.yml")).sort.map do |path|
          slug = File.basename(path, ".yml")
          data = load_yaml_file(path)
          { "slug" => slug, "title" => data["title"].to_s, "summary" => data["summary"].to_s }
        end
      end

      def find!(slug)
        path = BASE_DIR.join("#{slug}.yml")
        raise ActiveRecord::RecordNotFound, "Unknown lesson" unless File.exist?(path)
        load_yaml_file(path).merge("slug" => slug)
      end

      def raw_yaml(slug)
        path = BASE_DIR.join("#{slug}.yml")
        raise ActiveRecord::RecordNotFound, "Unknown lesson" unless File.exist?(path)
        File.read(path, encoding: "utf-8")
      end

      def write_raw!(slug, yaml_string)
        slug = slug.to_s.strip
        raise ArgumentError, "Slug required" if slug.empty?
        lesson = parse_yaml_string!(yaml_string)
        # Ensure slug is consistent with filename
        lesson["slug"] = slug
        BASE_DIR.mkpath
        File.write(BASE_DIR.join("#{slug}.yml"), dump_yaml(lesson), encoding: "utf-8")
      end

      def parse_yaml_string!(yaml_string)
        data = YAML.safe_load(yaml_string, permitted_classes: [], permitted_symbols: [], aliases: false) || {}
        deep_indifferent!(data)
      rescue Psych::SyntaxError => e
        raise ArgumentError, "YAML error: #{e.message}"
      end

      def template_yaml
        <<~YAML
          schema_version: 1
          title: New lesson
          summary: ""
          blocks:
            - type: context
              title: Context
              body: |
                Write the world-building here.
        YAML
      end

      def dump_yaml(lesson_hash)
        # Keep output stable and human-editable.
        YAML.dump(lesson_hash)
      end

      private

      def load_yaml_file(path)
        data = YAML.safe_load(File.read(path, encoding: "utf-8"), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
        deep_indifferent!(data)
      rescue Psych::SyntaxError => e
        raise ArgumentError, "YAML error in #{path}: #{e.message}"
      end

      def deep_indifferent!(obj)
        case obj
        when Hash
          obj.keys.each do |k|
            v = obj.delete(k)
            obj[k.to_s] = deep_indifferent!(v)
          end
          obj
        when Array
          obj.map! { |v| deep_indifferent!(v) }
        else
          obj
        end
      end
    end
  end
end
