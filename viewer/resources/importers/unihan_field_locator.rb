# frozen_string_literal: true

module Importers
  # Helper to locate which Unihan-style TSV file contains a given field (e.g. "kIDS").
  #
  # We search for lines containing: "\t<field>\t"
  # and return the first matching filename.
  class UnihanFieldLocator
    def self.find_file_with_field(root_dir:, field:, glob: "*.txt", max_lines_per_file: 500_000)
      root = Rails.root.join(root_dir)
      raise "Root dir not found: #{root}" unless Dir.exist?(root)

      needle = "\t#{field}\t"
      files = Dir.glob(root.join(glob)).sort

      files.each do |full_path|
        line_no = 0
        File.foreach(full_path, encoding: "UTF-8") do |line|
          line_no += 1
          next if line.start_with?("#")
          if line.include?(needle)
            rel = Pathname.new(full_path).relative_path_from(Rails.root).to_s
            return rel
          end
          break if line_no >= max_lines_per_file
        end
      rescue => e
        warn "[UnihanFieldLocator] Skipping #{full_path}: #{e.class}: #{e.message}"
      end

      nil
    end
  end
end
