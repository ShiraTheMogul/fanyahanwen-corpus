# frozen_string_literal: true

class AllowRawOnlyChengyuEtymologies < ActiveRecord::Migration[8.1]
  def up
    change_column_null :chengyu_etymologies, :plain_text, true
  end

  def down
    execute <<~SQL.squish
      UPDATE chengyu_etymologies
      SET plain_text = COALESCE(plain_text, raw_wikitext, '')
      WHERE plain_text IS NULL
    SQL
    change_column_null :chengyu_etymologies, :plain_text, false
  end
end
