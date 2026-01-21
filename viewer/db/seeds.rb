# Seeds are intentionally small and repeatable.
#
# Pattern: reference datasets (like Kangxi radicals) live as CSVs in db/seed_data/
# and are imported only if the target table is empty.

require "csv"

def seed_csv_if_empty(model_class, csv_path)
  return unless model_class.count == 0
  return unless File.exist?(csv_path)

  CSV.foreach(csv_path, headers: true) do |row|
    model_class.create!(
      number: row["Number"].to_i,
      radical: row["Radical"],
      variants: row["Variants"],
      stroke_count: row["Stroke count"]&.to_i,
      meaning: row["Meaning"],
      colloquial_names: row["Colloquial / Traditional names"],
      pinyin: row["Pinyin (Mandarin)"],
      sino_vietnamese: row["Vietnamese (Sino-Vietnamese)"],
      japanese: row["Japanese (On/Kun/Romaji)"],
      korean: row["Korean (Hanja / Hangul-Romaja)"],
      frequency: row["Frequency"]&.to_i,
      simplified: row["Simplified"],
      examples: row["Examples"],
    )
  end
end

seed_csv_if_empty(KangxiRadical, Rails.root.join("db", "seed_data", "kangxi_radicals.csv"))
