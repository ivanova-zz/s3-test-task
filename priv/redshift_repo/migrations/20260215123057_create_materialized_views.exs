defmodule S3TestTask.RedshiftRepo.Migrations.CreateMaterializedViews do
  use Ecto.Migration
  @disable_ddl_transaction true
  def up do
    execute """
    CREATE MATERIALIZED VIEW mv_collisions_by_district_year AS
    SELECT
      dl.district,
      dd.year,
      COUNT(*) AS total_collisions,
      SUM(fc.num_vehicles) AS total_vehicles,
      SUM(fc.num_casualties) AS total_casualties,
      AVG(fc.speed_limit) AS avg_speed_limit,
      SUM(CASE WHEN dd.is_weekend THEN 1 ELSE 0 END) AS weekend_collisions,
      SUM(CASE WHEN dt.rush_hour THEN 1 ELSE 0 END) AS rush_hour_collisions
    FROM fact_collision fc
    JOIN dim_date dd ON dd.date_key = fc.date_key
    JOIN dim_time dt ON dt.time_key = fc.time_key
    LEFT JOIN dim_location dl ON dl.location_key = fc.location_key
    GROUP BY dl.district, dd.year
    """

    execute """
    CREATE MATERIALIZED VIEW mv_casualty_severity AS
    SELECT
      dd.year,
      dd.month,
      lsev.name AS severity_name,
      lclass.name AS casualty_class_name,
      dp.sex_code,
      lsex.name AS sex_name,
      dp.age_group_code,
      lage.name AS age_group_name,
      COUNT(*) AS total_casualties,
      SUM(fca.severity_score) AS total_severity_score,
      SUM(CASE WHEN fca.is_school_pupil THEN 1 ELSE 0 END) AS school_pupils
    FROM fact_casualty fca
    JOIN fact_collision fc ON fc.collision_id = fca.collision_id
    JOIN dim_date dd ON dd.date_key = fc.date_key
    LEFT JOIN dim_casualty_type dct ON dct.casualty_type_key = fca.casualty_type_key
    LEFT JOIN dim_person dp ON dp.person_key = fca.person_key
    LEFT JOIN dim_code_lookup lsev ON lsev.column_name = 'c_sever' AND lsev.code = dct.severity_code
    LEFT JOIN dim_code_lookup lclass ON lclass.column_name = 'c_class' AND lclass.code = dct.class_code
    LEFT JOIN dim_code_lookup lsex ON lsex.column_name = 'c_sex' AND lsex.code = dp.sex_code
    LEFT JOIN dim_code_lookup lage ON lage.column_name = 'c_agegroup' AND lage.code = dp.age_group_code
    GROUP BY dd.year, dd.month, lsev.name, lclass.name, dp.sex_code, lsex.name, dp.age_group_code, lage.name
    """

    execute """
    CREATE MATERIALIZED VIEW mv_vehicle_involvement AS
    SELECT
      dd.year,
      dvt.type_code,
      ltype.name AS vehicle_type_name,
      COUNT(*) AS total_vehicles,
      SUM(CASE WHEN fv.hit_and_run_code != '0' AND fv.hit_and_run_code != '-1' THEN 1 ELSE 0 END) AS hit_and_run_count,
      SUM(CASE WHEN fv.foreign_registered = '1' THEN 1 ELSE 0 END) AS foreign_registered_count
    FROM fact_vehicle fv
    JOIN fact_collision fc ON fc.collision_id = fv.collision_id
    JOIN dim_date dd ON dd.date_key = fc.date_key
    LEFT JOIN dim_vehicle_type dvt ON dvt.vehicle_type_key = fv.vehicle_type_key
    LEFT JOIN dim_code_lookup ltype ON ltype.column_name = 'v_type' AND ltype.code = dvt.type_code
    GROUP BY dd.year, dvt.type_code, ltype.name
    """

    execute """
    CREATE MATERIALIZED VIEW mv_time_patterns AS
    SELECT
      dd.year,
      dd.day_of_week,
      dd.day_name,
      dt.hour,
      dt.time_of_day,
      dt.rush_hour,
      dd.is_weekend,
      COUNT(*) AS total_collisions,
      SUM(fc.num_casualties) AS total_casualties,
      AVG(fc.speed_limit) AS avg_speed_limit
    FROM fact_collision fc
    JOIN dim_date dd ON dd.date_key = fc.date_key
    JOIN dim_time dt ON dt.time_key = fc.time_key
    GROUP BY dd.year, dd.day_of_week, dd.day_name, dt.hour, dt.time_of_day, dt.rush_hour, dd.is_weekend
    """

    execute """
    CREATE MATERIALIZED VIEW mv_weather_impact AS
    SELECT
      dd.year,
      dw.weather_code,
      lweat.name AS weather_name,
      dw.light_code,
      llight.name AS light_name,
      dw.road_surface_code,
      lroad.name AS road_surface_name,
      COUNT(*) AS total_collisions,
      SUM(fc.num_casualties) AS total_casualties,
      SUM(fc.num_vehicles) AS total_vehicles,
      AVG(fc.speed_limit) AS avg_speed_limit
    FROM fact_collision fc
    JOIN dim_date dd ON dd.date_key = fc.date_key
    LEFT JOIN dim_weather dw ON dw.weather_key = fc.weather_key
    LEFT JOIN dim_code_lookup lweat ON lweat.column_name = 'a_weat' AND lweat.code = dw.weather_code
    LEFT JOIN dim_code_lookup llight ON llight.column_name = 'a_light' AND llight.code = dw.light_code
    LEFT JOIN dim_code_lookup lroad ON lroad.column_name = 'a_roadsc' AND lroad.code = dw.road_surface_code
    GROUP BY dd.year, dw.weather_code, lweat.name, dw.light_code, llight.name, dw.road_surface_code, lroad.name
    """

    execute """
    CREATE MATERIALIZED VIEW mv_manoeuvre_impact AS
    SELECT
      dd.year,
      dm.manoeuvre_code,
      lman.name AS manoeuvre_name,
      di.skidding_code,
      lskid.name AS skidding_name,
      di.first_impact_code,
      limpact.name AS first_impact_name,
      COUNT(*) AS total_vehicles,
      COUNT(DISTINCT fv.collision_id) AS total_collisions
    FROM fact_vehicle fv
    JOIN fact_collision fc ON fc.collision_id = fv.collision_id
    JOIN dim_date dd ON dd.date_key = fc.date_key
    LEFT JOIN dim_manoeuvre dm ON dm.manoeuvre_key = fv.manoeuvre_key
    LEFT JOIN dim_impact di ON di.impact_key = fv.impact_key
    LEFT JOIN dim_code_lookup lman ON lman.column_name = 'v_man' AND lman.code = dm.manoeuvre_code
    LEFT JOIN dim_code_lookup lskid ON lskid.column_name = 'v_skid' AND lskid.code = di.skidding_code
    LEFT JOIN dim_code_lookup limpact ON limpact.column_name = 'v_impact' AND limpact.code = di.first_impact_code
    GROUP BY dd.year, dm.manoeuvre_code, lman.name, di.skidding_code, lskid.name, di.first_impact_code, limpact.name
    """

    execute """
    CREATE MATERIALIZED VIEW mv_monthly_trend AS
    SELECT
      dd.year,
      dd.month,
      dd.month_name,
      COUNT(DISTINCT fc.collision_id) AS total_collisions,
      SUM(fc.num_casualties) AS total_casualties,
      SUM(fc.num_vehicles) AS total_vehicles,
      AVG(fc.speed_limit) AS avg_speed_limit,
      SUM(CASE WHEN dd.is_weekend THEN 1 ELSE 0 END) AS weekend_collisions,
      COUNT(DISTINCT fc.collision_id) * 1.0 /
        COUNT(DISTINCT dd.full_date) AS avg_collisions_per_day
    FROM fact_collision fc
    JOIN dim_date dd ON dd.date_key = fc.date_key
    GROUP BY dd.year, dd.month, dd.month_name
    """
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_monthly_trend"
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_manoeuvre_impact"
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_weather_impact"
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_time_patterns"
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_vehicle_involvement"
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_casualty_severity"
    execute "DROP MATERIALIZED VIEW IF EXISTS mv_collisions_by_district_year"
  end
end
