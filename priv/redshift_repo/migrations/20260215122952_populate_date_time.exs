defmodule S3TestTask.RedshiftRepo.Migrations.PopulateDateTime do
  use Ecto.Migration
  @disable_ddl_transaction true
  def up do
    # Populate dim_date (2017-2025)
    execute """
    INSERT INTO dim_date (date_key, full_date, year, month, month_name, day, day_of_week, day_name, is_weekend, quarter)
    WITH
      d0 AS (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
      ),
      d1 AS (SELECT a.n * 10 + b.n AS n FROM d0 a CROSS JOIN d0 b),
      d2 AS (SELECT a.n * 100 + b.n AS n FROM d1 a CROSS JOIN d0 b),
      nums AS (SELECT a.n * 1000 + b.n AS n FROM d0 a CROSS JOIN d2 b WHERE a.n * 1000 + b.n <= 2191)
    SELECT
      CAST(TO_CHAR(datum, 'YYYYMMDD') AS INT),
      datum,
      EXTRACT(YEAR FROM datum)::SMALLINT,
      EXTRACT(MONTH FROM datum)::SMALLINT,
      TRIM(TO_CHAR(datum, 'Month')),
      EXTRACT(DAY FROM datum)::SMALLINT,
      EXTRACT(DOW FROM datum)::SMALLINT,
      TRIM(TO_CHAR(datum, 'Day')),
      CASE WHEN EXTRACT(DOW FROM datum) IN (0, 6) THEN TRUE ELSE FALSE END,
      EXTRACT(QUARTER FROM datum)::SMALLINT
    FROM (
      SELECT (DATE '2017-01-01' + n)::DATE AS datum
      FROM nums
    )
    WHERE NOT EXISTS (SELECT 1 FROM dim_date LIMIT 1)
    """

    # Populate dim_time (00:00 - 23:59 = 1440 minutes)
    execute """
    INSERT INTO dim_time (time_key, hour, minute, time_of_day, rush_hour)
    WITH
      d0 AS (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
      ),
      d1 AS (SELECT a.n * 10 + b.n AS n FROM d0 a CROSS JOIN d0 b),
      d2 AS (SELECT a.n * 100 + b.n AS n FROM d1 a CROSS JOIN d0 b),
      nums AS (SELECT n FROM d2 WHERE n <= 1439)
    SELECT
      (h * 100 + m)::SMALLINT AS time_key,
      h::SMALLINT AS hour,
      m::SMALLINT AS minute,
      CASE
        WHEN h BETWEEN 5 AND 11 THEN 'Morning'
        WHEN h BETWEEN 12 AND 16 THEN 'Afternoon'
        WHEN h BETWEEN 17 AND 20 THEN 'Evening'
        ELSE 'Night'
      END AS time_of_day,
      CASE WHEN h IN (7,8,9,17,18,19) THEN TRUE ELSE FALSE END AS rush_hour
    FROM (
      SELECT
        (n / 60)::INT AS h,
        (n % 60)::INT AS m
      FROM nums
    )
    WHERE NOT EXISTS (SELECT 1 FROM dim_time LIMIT 1)
    """
  end

  def down do
    execute "TRUNCATE TABLE dim_time"
    execute "TRUNCATE TABLE dim_date"
  end
end
