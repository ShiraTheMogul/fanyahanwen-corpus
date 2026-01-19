# app/services/importers/shuowen_importer.rb
#
# Purpose:
# - Load Shuowen Jiezi data from an .xlsx into character_properties.
# - Each row becomes up to TWO properties:
#     (1) field: shuowen_category (e.g. "目部")
#     (2) field: shuowen_entry    (the full definition text)
#
# Why two fields?
# - shuowen_category is the "component class" Xu Shen grouped entries under.
# - shuowen_entry is the entry text you want to show on the character page.

module Importers
  class ShuowenImporter
    def self.import_xlsx(path, source: "Shuowen Jiezi", limit: nil, verbose: true)
      require "roo"

      xlsx = Roo::Excelx.new(path)
      sheet = xlsx.sheet(0)

      headers = sheet.row(1).map { |h| h.to_s.strip }

      col = ->(name) { headers.index(name) ? headers.index(name) + 1 : nil }

      category_col = col.call("shuowen_category")
      char_col     = col.call("character")
      entry_col    = col.call("entry")

      raise "Missing required columns" if char_col.nil? || entry_col.nil?

      imported = 0
      skipped  = 0

      last = sheet.last_row
      last = [last, 1 + limit].min if limit

      (2..last).each do |row_num|
        chr = sheet.cell(row_num, char_col).to_s.strip
        ent = sheet.cell(row_num, entry_col).to_s.strip
        cat = category_col ? sheet.cell(row_num, category_col).to_s.strip : ""

        if chr.empty? || ent.empty?
          skipped += 1
          next
        end

        # Safety: some rows might accidentally have multiple chars.
        # For Shuowen we expect a single head character.
        head_char = chr[0]
        codepoint = head_char.ord

        cp = CharacterCodepoint.find_or_create_by(codepoint: codepoint) do |c|
          c.chr = head_char
        end

        # 1) category (only if present)
        if cat.present?
          begin
            CharacterProperty.create!(
              character_codepoint_id: cp.id,
              source: source,
              field: "shuowen_category",
              value: cat
            )
          rescue ActiveRecord::RecordNotUnique
            # duplicate - ignore
          end
        end

        # 2) entry text
        begin
          CharacterProperty.create!(
            character_codepoint_id: cp.id,
            source: source,
            field: "shuowen_entry",
            value: ent
          )
        rescue ActiveRecord::RecordNotUnique
          # duplicate - ignore
        end

        imported += 1

        if verbose && (imported % 500 == 0)
          puts "[Shuowen] imported=#{imported} row=#{row_num}/#{last}"
        end
      end

      { imported: imported, skipped: skipped }
    end
  end
end
