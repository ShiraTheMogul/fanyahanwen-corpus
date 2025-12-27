module Importers

  # This is the importer class. Think: "a tool with methods".
  class CedictImporter

    # This is a "class method" (it belongs to the class itself, not an instance).
    # You will call it like: Importers::CedictImporter.import_file("path", ...)
    #
    # Parameters explained:
    # - path: where the cedict file lives
    # - source: string label stored in DB so you can filter/delete later (e.g. "CC-CEDICT")
    # - limit: import only N good lines (useful for testing)
    def self.import_file(path, source:, limit: nil)

      # Counters so you can see what happened after the run.
      imported = 0
      skipped  = 0
      bad      = 0
      seen     = 0

      # File.foreach reads ONE line at a time (does NOT load the whole file).
      # encoding: "UTF-8" matters because this file contains Han characters.
      File.foreach(path, encoding: "UTF-8") do |line|

        # line.strip removes leading/trailing whitespace and the newline at the end.
        line = line.strip

        # Skip empty lines.
        if line.empty?
          skipped += 1
          next
        end

        # Skip comment lines that start with "#".
        if line.start_with?("#")
          skipped += 1
          next
        end

        # This regex is the "shape" of a normal CEDICT entry:
        # TRAD SIMP [PINYIN] /def1/def2/.../
        #
        # What each part means:
        # - \A ... \z : match the whole line from start to end
        # - (\S+) : group 1 = "non-space characters" -> TRAD
        # - \s+   : one or more spaces
        # - (\S+) : group 2 = SIMP
        # - \s+   : spaces
        # - \[([^\]]+)\] : group 3 = inside [ ... ] -> PINYIN
        # - \s+   : spaces
        # - (/.+/) : group 4 = everything from the first "/" onward -> defs block
        m = line.match(/\A(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+(\/.+\/)\z/)

        # If the line doesn't match that shape, count it as bad and move on.
        if m.nil?
          bad += 1
          next
        end

        # Extract the pieces from the match groups.
        trad  = m[1]  # traditional headword
        simp  = m[2]  # simplified headword
        py    = m[3]  # pinyin inside brackets
        defs_blob = m[4]  # e.g. "/def1/def2/"

        # File: app/services/importers/cedict_importer.rb
        # Import rule: keep only 1-character headwords for the character dictionary view.
        # If trad is more than one character, skip for now.
        if trad.length != 1
          skipped += 1
          next
        end

        # Convert defs_blob "/a/b/c/" into ["a","b","c"]
        # - split("/") breaks it into pieces
        # - reject(&:empty?) removes empty strings caused by leading/trailing slashes
        defs = defs_blob.split("/").reject(&:empty?)

        # Compute Unicode codepoint number from the character.
        # Example: "普".ord == 26222
        codepoint = trad.ord

        # Find existing character row OR create it if missing.
        #
        # find_or_create_by! means:
        # - try to find a row matching codepoint
        # - if not found, insert a new row
        # - the "!" means: if something goes wrong, raise an error loudly
        cp = CharacterCodepoint.find_or_create_by!(codepoint: codepoint) do |row|
          # This block runs only when it is creating a NEW row.
          row.chr = trad
        end

        # Helper: create a property row safely.
        #
        # begin/rescue is used because a unique index can reject duplicates.
        # If a duplicate happens, we count it as skipped and keep going.
        begin
          CharacterProperty.create!(
            character_codepoint_id: cp.id,
            source: source,
            field:  "cedict_simp",
            value:  simp
          )
        rescue ActiveRecord::RecordNotUnique
          skipped += 1
        end

        begin
          CharacterProperty.create!(
            character_codepoint_id: cp.id,
            source: source,
            field:  "cedict_pinyin",
            value:  py
          )
        rescue ActiveRecord::RecordNotUnique
          skipped += 1
        end

        # One definition = one property row.
        defs.each do |d|
          begin
            CharacterProperty.create!(
              character_codepoint_id: cp.id,
              source: source,
              field:  "cedict_def",
              value:  d
            )
          rescue ActiveRecord::RecordNotUnique
            skipped += 1
          end
        end

        imported += 1
        seen += 1

        # limit means: stop after N successfully imported entries.
        if limit && imported >= limit
          break
        end

        # Print progress every 1000 imported entries so you know it’s working.
        if imported % 1000 == 0
          puts "Imported #{imported} entries so far..."
        end
      end

      # Return a summary hash so rails runner prints something helpful.
      { imported: imported, skipped: skipped, bad_lines: bad }
    end
  end
end
