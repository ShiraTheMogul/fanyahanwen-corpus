class AllowNullSubgroupOnDailyReadings < ActiveRecord::Migration[8.1]
  def change
    change_column_null :daily_readings, :subgroup, true
  end
end
