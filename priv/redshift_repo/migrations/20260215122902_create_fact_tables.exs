defmodule S3TestTask.RedshiftRepo.Migrations.CreateFactTables do
  use Ecto.Migration
  @disable_ddl_transaction true
  def up do
    # fact_collision — главная таблица фактов о ДТП
    execute """
    CREATE TABLE IF NOT EXISTS fact_collision (
      collision_key BIGINT IDENTITY(1,1) PRIMARY KEY,
      collision_id VARCHAR(255) NOT NULL,

      -- Dimension keys
      date_key INT,
      time_key INT,
      location_key INT,
      weather_key INT,
      junction_key INT,

      -- Degenerate dimensions
      year INT,
      accident_ref VARCHAR(255),
      accident_type VARCHAR(255),
      collision_type_code VARCHAR(255),
      speed_limit INT,

      -- Measures
      num_vehicles INT,
      num_casualties INT,

      -- Pedestrian factors
      pedestrian_human_factor VARCHAR(255),
      pedestrian_physical_factor VARCHAR(255),

      -- Scene
      accident_scene_code VARCHAR(255),

      -- Metadata
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

      UNIQUE(collision_id)
    )
    DISTSTYLE KEY
    DISTKEY (location_key)
    SORTKEY (year, date_key)
    """

    # fact_vehicle — транспортные средства в ДТП
    execute """
    CREATE TABLE IF NOT EXISTS fact_vehicle (
      vehicle_fact_key BIGINT IDENTITY(1,1) PRIMARY KEY,

      -- Natural keys
      vehicle_id VARCHAR(50) NOT NULL,
      collision_id VARCHAR(50) NOT NULL,

      -- Dimension keys
      vehicle_type_key INT,
      manoeuvre_key INT,
      impact_key INT,
      driver_key INT,

      -- Degenerate dimensions
      year INT,
      accident_ref VARCHAR(255),
      vehicle_ref VARCHAR(255),

      -- Flags
      hit_and_run_code VARCHAR(255),
      foreign_registered VARCHAR(255),

      -- Metadata
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

      UNIQUE(collision_id, vehicle_id)
    )
    DISTSTYLE KEY
    DISTKEY (collision_id)
    SORTKEY (year)
    """

    # fact_casualty — пострадавшие в ДТП
    execute """
    CREATE TABLE IF NOT EXISTS fact_casualty (
      casualty_fact_key BIGINT IDENTITY(1,1) PRIMARY KEY,

      -- Natural keys
      casualty_id VARCHAR(255) NOT NULL,
      collision_id VARCHAR(255) NOT NULL,
      vehicle_id VARCHAR(255),

      -- Dimension keys
      casualty_type_key INT,
      person_key INT,
      vehicle_type_key INT,

      -- Degenerate dimensions
      year INT,
      accident_ref VARCHAR(255),
      casualty_ref VARCHAR(255),

      -- Measures
      severity_score INT,

      -- Flags
      is_school_pupil BOOLEAN DEFAULT FALSE,
      pcv_passenger VARCHAR(255),

      -- Metadata
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

      UNIQUE(collision_id, casualty_id)
    )
    DISTSTYLE KEY
    DISTKEY (collision_id)
    SORTKEY (year)
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS fact_casualty"
    execute "DROP TABLE IF EXISTS fact_vehicle"
    execute "DROP TABLE IF EXISTS fact_collision"
  end
end
