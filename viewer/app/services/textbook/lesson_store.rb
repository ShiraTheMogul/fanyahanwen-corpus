# frozen_string_literal: true

require "yaml"
require "fileutils"

module Textbook
  class LessonStore
    LESSONS_DIR = Rails.root.join("config", "textbook", "lessons")

    # Existing API (kept):
    # - .all -> array of parsed lesson hashes
    # - .find!(slug) -> parsed lesson hash
    #
    # Editor/API additions (new):
    # - .list -> array of slugs (strings)
    # - .load_raw!(slug) -> raw YAML string
    # - .write_raw!(slug, raw_yaml) -> writes YAML to disk
    #
    # These methods are intentionally simple so they stay stable while we build the authoring UI.

    def self.all
      Dir.glob(LESSONS_DIR.join("*.yml")).sort.map { |p| load_lesson(p) }
    end

    # Return slugs (filenames without extension), sorted.
    # This is used by the editor index and any future "lesson picker".
    def self.list
      Dir.glob(LESSONS_DIR.join("*.yml"))
         .map { |p| File.basename(p, ".yml") }
         .sort
    end

    def self.find!(slug)
      path = LESSONS_DIR.join("#{slug}.yml")
      raise ActiveRecord::RecordNotFound, "Unknown lesson" unless File.exist?(path)
      load_lesson(path)
    end

    def self.load_raw!(slug)
      path = LESSONS_DIR.join("#{slug}.yml")
      raise ActiveRecord::RecordNotFound, "Unknown lesson" unless File.exist?(path)
      File.read(path)
    end

    def self.write_raw!(slug, raw_yaml)
      # FileUtils.mkdir_p works on strings/paths; Pathname instances do not have mkdir_p.
      FileUtils.mkdir_p(LESSONS_DIR.to_s)
      path = LESSONS_DIR.join("#{slug}.yml")
      File.write(path, raw_yaml.to_s)
      true
    end

    def self.load_lesson(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [Date], aliases: true)
      unless raw.is_a?(Hash)
        raise "Lesson YAML must be a mapping: #{path}"
      end
      raw["slug"] ||= File.basename(path, ".yml")
      raw
    end
  end
end
