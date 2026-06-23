module Importers
  # module = a namespace (a "folder" for Ruby constants/classes)
  # It prevents name collisions, like having two classes called Importer.

  class KangxiImporter
    # class = a blueprint for methods. 

    def self.import_xlsx(path, source: "Kangxi", limit: nil, verbose: true)
      # self.import_xlsx = a "class method". Call as: Importers::KangxiImporter.import_xlsx)
      # path = required argument (aka put the file path in ur cmd)
      # source:, limit:, verbose: are keyword arguments with default values

      require "roo"
      # require loads a gem/library at runtime.
      # "roo" lets Ruby read Excel files; otherwise csvs are the best I get.

      xlsx = Roo::Excelx.new(path)
      # Roo::Excelx is Roo’s Excel reader for .xlsx
      # .new(path) opens that file

      sheet = xlsx.sheet(0)
      # sheet(0) selects the first worksheet tab (0-based index)

      headers = sheet.row(1).map { |h| h.to_s.strip }
      # sheet.row(1) reads row 1 as an array (Excel rows are 1-based)
      # map { ... } transforms every header cell
      # h.to_s makes nil safe (nil.to_s -> "")
      # strip removes surrounding whitespace

      col = ->(name) { headers.index(name) ? headers.index(name) + 1 : nil }
      # ->(name) { ... } is a lambda (a little function stored in a variable)
      # headers.index(name) gives 0-based index or nil if not found
      # +1 converts it to Excel column numbers (1-based)
      # ?: is the "ternary" operator (if/else in one line)

      trad_col  = col.call("繁體")
      # col.call(...) runs the lambda
      # trad_col becomes the column number containing 繁體

      gloss_col = col.call("康熙字典解釋")
      # same idea for the definition column

      raise "Missing required columns" if trad_col.nil? || gloss_col.nil?
      # raise stops immediately with an error message (good for "this file isn’t what we expect")
	  # this likely won't trigger. it's just safety. 

      imported = 0
      skipped  = 0

      last = sheet.last_row
      # last_row returns how many rows exist!

      last = [last, 1 + limit].min if limit
      # if limit is not nil, we reduce last so we only process that many rows
      # [a,b].min picks the smaller
      # +1 because row 1 is headers

      (2..last).each do |row_num|
        # (2..last) is a Range. each iterates row_num = 2,3,4...
        # do |row_num| starts a block (Ruby block syntax)

        trad = sheet.cell(row_num, trad_col).to_s.strip
        # sheet.cell(row, col) reads one cell
        # to_s.strip makes it safe and clean

        if trad.empty?
          # if = conditional
          skipped += 1
          # += increments (skipped = skipped + 1)
          next
          # next skips to the next loop iteration
        end

        codepoint = trad.ord
        # .ord converts the character to its Unicode codepoint integer

        cp = CharacterCodepoint.find_or_create_by(codepoint: codepoint) do |c|
          # find_or_create_by searches by given fields; creates if missing
          # do |c| is a block that runs ONLY when creating a new record
          c.chr = trad
          # set the chr column when new
        end

        gloss = sheet.cell(row_num, gloss_col).to_s.strip
        # read the gloss cell

        if !gloss.empty?
          # ! means "not"
          begin
            # begin starts an exception-handling region
            CharacterProperty.create!(
              # create! writes to DB and raises if invalid
              character_codepoint_id: cp.id,
              source: source,
              field: "kangxi_gloss",
              value: gloss
            )
          rescue ActiveRecord::RecordNotUnique
            # rescue catches a specific error (duplicate due to unique index)
            # do nothing -> skip duplicates safely
          end
        end

        imported += 1

        if verbose && (imported % 500 == 0)
          # && means "and"
          # imported % 500 == 0 means "every 500 rows"
          puts "[Kangxi] imported=#{imported} row=#{row_num}/#{last}"
          # #{...} is string interpolation (inserts the value into the string)
        end
      end

      { imported: imported, skipped: skipped }
      # return a hash with results (Ruby returns last expression automatically)
    end
  end
end
