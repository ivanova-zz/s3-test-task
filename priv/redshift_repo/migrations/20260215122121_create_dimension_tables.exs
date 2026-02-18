defmodule S3TestTask.RedshiftRepo.Migrations.CreateDimensionTables do
  use Ecto.Migration
  @disable_ddl_transaction true
  def up do
    execute """
    CREATE TABLE IF NOT EXISTS dim_code_lookup (
      column_name VARCHAR(50),
      code VARCHAR(20),
      name VARCHAR(200),
      PRIMARY KEY (column_name, code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_date (
      date_key INT PRIMARY KEY,
      full_date DATE,
      year INT,
      month INT,
      month_name VARCHAR(20),
      day INT,
      day_of_week INT,
      day_name VARCHAR(20),
      is_weekend BOOLEAN,
      quarter INT
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_time (
      time_key INT PRIMARY KEY,
      hour INT,
      minute INT,
      time_of_day VARCHAR(20),
      rush_hour BOOLEAN
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_location (
      location_key INT IDENTITY(1,1) PRIMARY KEY,
      district VARCHAR(100),
      grid_ref_1 VARCHAR(50),
      grid_ref_2 VARCHAR(50),
      UNIQUE(district, grid_ref_1, grid_ref_2)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_weather (
      weather_key INT IDENTITY(1,1) PRIMARY KEY,
      weather_code VARCHAR(255),
      light_code VARCHAR(255),
      road_surface_code VARCHAR(255),
      special_conditions_code VARCHAR(255),
      carriageway_hazard_code VARCHAR(255),
      UNIQUE(weather_code, light_code, road_surface_code, special_conditions_code, carriageway_hazard_code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_junction (
      junction_key INT IDENTITY(1,1) PRIMARY KEY,
      junction_detail_code VARCHAR(255),
      junction_control_code VARCHAR(255),
      UNIQUE(junction_detail_code, junction_control_code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_casualty_type (
      casualty_type_key INT IDENTITY(1,1) PRIMARY KEY,
      class_code VARCHAR(255),
      severity_code VARCHAR(255),
      severity_score INT,
      location_code VARCHAR(255),
      movement_code VARCHAR(255),
      pedestrian_injury_code VARCHAR(255),
      UNIQUE(class_code, severity_code, location_code, movement_code, pedestrian_injury_code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_vehicle_type (
      vehicle_type_key INT IDENTITY(1,1) PRIMARY KEY,
      type_code VARCHAR(255),
      towing_code VARCHAR(255),
      UNIQUE(type_code, towing_code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_manoeuvre (
      manoeuvre_key INT IDENTITY(1,1) PRIMARY KEY,
      manoeuvre_code VARCHAR(255),
      vehicle_location_code VARCHAR(255),
      junction_location_code VARCHAR(255),
      UNIQUE(manoeuvre_code, vehicle_location_code, junction_location_code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_impact (
      impact_key INT IDENTITY(1,1) PRIMARY KEY,
      skidding_code VARCHAR(255),
      hit_object_code VARCHAR(255),
      leave_carriageway_code VARCHAR(255),
      hit_object_off_code VARCHAR(255),
      first_impact_code VARCHAR(255),
      UNIQUE(skidding_code, hit_object_code, leave_carriageway_code, hit_object_off_code, first_impact_code)
    )
    DISTSTYLE ALL
    """

    execute """
    CREATE TABLE IF NOT EXISTS dim_person (
      person_key INT IDENTITY(1,1) PRIMARY KEY,
      sex_code VARCHAR(10),
      age_group_code VARCHAR(20),
      UNIQUE(sex_code, age_group_code)
    )
    DISTSTYLE ALL
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS dim_person"
    execute "DROP TABLE IF EXISTS dim_impact"
    execute "DROP TABLE IF EXISTS dim_manoeuvre"
    execute "DROP TABLE IF EXISTS dim_vehicle_type"
    execute "DROP TABLE IF EXISTS dim_casualty_type"
    execute "DROP TABLE IF EXISTS dim_junction"
    execute "DROP TABLE IF EXISTS dim_weather"
    execute "DROP TABLE IF EXISTS dim_location"
    execute "DROP TABLE IF EXISTS dim_time"
    execute "DROP TABLE IF EXISTS dim_date"
    execute "DROP TABLE IF EXISTS dim_code_lookup"
  end
end
