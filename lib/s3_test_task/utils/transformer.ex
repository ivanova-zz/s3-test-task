defmodule S3TestTask.Utils.Transformer do
  alias S3TestTask.RedshiftRepo, as: Repo
  alias S3TestTask.Utils.EtlLog
  require Logger

  def transform(filename, staging_table) do
    Logger.info("[ETL] Starting transform: #{filename} from #{staging_table}")
    start = System.monotonic_time(:millisecond)

    result =
      cond do
        String.ends_with?(filename, "collision2017-2022.csv") ->
          transform_collision(staging_table)

        String.ends_with?(filename, "vehicle2017-2022.csv") ->
          transform_vehicle(staging_table)

        String.ends_with?(filename, "casualty2017-2022.csv") ->
          transform_casualty(staging_table)

        String.ends_with?(filename, "vehicle-index.csv") ->
          transform_code_lookup(staging_table)

        true ->
          {:error, "unknown file: #{filename}"}
      end

    duration = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, msg} ->
        Logger.info("[ETL] ✅ #{filename}: #{msg} (#{duration}ms)")
        EtlLog.log_success(filename, staging_table, msg, duration)
        drop_staging_table(staging_table)
        {:ok, msg}

      {:error, reason} ->
        Logger.error("[ETL] ❌ #{filename} failed: #{inspect(reason)} (#{duration}ms)")
        EtlLog.log_error(filename, staging_table, reason, duration)
        {:error, reason}
    end
  end

  defp drop_staging_table(table) do
    Logger.info("[ETL] Dropping staging table: #{table}")
    Repo.query("DROP TABLE IF EXISTS #{table}")
  end

  # ---- vehicle-index.csv → dim_code_lookup ----

  defp transform_code_lookup(stg) do
    run_step("dim_code_lookup", fn ->
      Repo.query("""
        INSERT INTO dim_code_lookup (column_name, code, name)
        SELECT col, dummy, name
        FROM #{stg}
        WHERE NOT EXISTS (
          SELECT 1 FROM dim_code_lookup d
          WHERE d.column_name = #{stg}.col
            AND d.code = #{stg}.dummy
        )
      """)
    end)
    |> case do
      {:ok, _} -> {:ok, "dim_code_lookup populated"}
      error -> error
    end
  end

  # ---- collision ----

  defp transform_collision(stg) do
    with {:ok, _} <- run_step("dim_location", fn -> populate_dim_location(stg) end),
         {:ok, _} <- run_step("dim_weather", fn -> populate_dim_weather(stg) end),
         {:ok, _} <- run_step("dim_junction", fn -> populate_dim_junction(stg) end),
         {:ok, _} <- run_step("fact_collision", fn -> populate_fact_collision(stg) end) do
      {:ok, "collision dimensions + facts populated"}
    end
  end

  defp populate_dim_location(stg) do
    Repo.query("""
      INSERT INTO dim_location (district, grid_ref_1, grid_ref_2)
      SELECT DISTINCT a_district, a_gd1, a_gd2
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_location d
        WHERE d.district = s.a_district
          AND d.grid_ref_1 = s.a_gd1
          AND d.grid_ref_2 = s.a_gd2
      )
    """)
  end

  defp populate_dim_weather(stg) do
    Repo.query("""
      INSERT INTO dim_weather (weather_code, light_code, road_surface_code, special_conditions_code, carriageway_hazard_code)
      SELECT DISTINCT a_weat, a_light, a_roadsc, a_speccs, a_chaz
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_weather d
        WHERE d.weather_code = s.a_weat
          AND d.light_code = s.a_light
          AND d.road_surface_code = s.a_roadsc
          AND d.special_conditions_code = s.a_speccs
          AND d.carriageway_hazard_code = s.a_chaz
      )
    """)
  end

  defp populate_dim_junction(stg) do
    Repo.query("""
      INSERT INTO dim_junction (junction_detail_code, junction_control_code)
      SELECT DISTINCT a_jdet, a_jcont
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_junction d
        WHERE d.junction_detail_code = s.a_jdet
          AND d.junction_control_code = s.a_jcont
      )
    """)
  end

  defp populate_fact_collision(stg) do
    Repo.query("""
      INSERT INTO fact_collision (
        collision_id, date_key, time_key, location_key, weather_key, junction_key,
        year, accident_ref, accident_type, collision_type_code, speed_limit,
        num_vehicles, num_casualties, pedestrian_human_factor, pedestrian_physical_factor, accident_scene_code
      )
      SELECT
        s.a_year || '-' || s.a_ref,
        CAST(s.a_year * 10000 + s.a_month * 100 + s.a_day AS INT),
        CAST(s.a_hour * 100 + s.a_min AS INT),
        dl.location_key, dw.weather_key, dj.junction_key,
        s.a_year, s.a_ref, s.a_type, s.a_ctype, CAST(NULLIF(s.a_speed, '') AS INT),
        CAST(NULLIF(s.a_veh, '') AS INT), s.a_cas, s.a_pedhum, s.a_pedphys, s.a_scene
      FROM #{stg} s
      LEFT JOIN dim_location dl
        ON dl.district = s.a_district AND dl.grid_ref_1 = s.a_gd1 AND dl.grid_ref_2 = s.a_gd2
      LEFT JOIN dim_weather dw
        ON dw.weather_code = s.a_weat AND dw.light_code = s.a_light
        AND dw.road_surface_code = s.a_roadsc AND dw.special_conditions_code = s.a_speccs
        AND dw.carriageway_hazard_code = s.a_chaz
      LEFT JOIN dim_junction dj
        ON dj.junction_detail_code = s.a_jdet AND dj.junction_control_code = s.a_jcont
      WHERE NOT EXISTS (
        SELECT 1 FROM fact_collision f WHERE f.collision_id = s.a_year || '-' || s.a_ref
      )
    """)
  end

  # ---- vehicle ----

  defp transform_vehicle(stg) do
    with {:ok, _} <- run_step("dim_vehicle_type", fn -> populate_dim_vehicle_type(stg) end),
         {:ok, _} <- run_step("dim_manoeuvre", fn -> populate_dim_manoeuvre(stg) end),
         {:ok, _} <- run_step("dim_impact", fn -> populate_dim_impact(stg) end),
         {:ok, _} <-
           run_step("dim_person (vehicle)", fn -> populate_dim_person_from_vehicle(stg) end),
         {:ok, _} <- run_step("fact_vehicle", fn -> populate_fact_vehicle(stg) end) do
      {:ok, "vehicle dimensions + facts populated"}
    end
  end

  defp populate_dim_vehicle_type(stg) do
    Repo.query("""
      INSERT INTO dim_vehicle_type (type_code, towing_code)
      SELECT DISTINCT v_type, v_tow
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_vehicle_type d
        WHERE d.type_code = s.v_type AND d.towing_code = s.v_tow
      )
    """)
  end

  defp populate_dim_manoeuvre(stg) do
    Repo.query("""
      INSERT INTO dim_manoeuvre (manoeuvre_code, vehicle_location_code, junction_location_code)
      SELECT DISTINCT v_man, v_loc, v_junc
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_manoeuvre d
        WHERE d.manoeuvre_code = s.v_man
          AND d.vehicle_location_code = s.v_loc
          AND d.junction_location_code = s.v_junc
      )
    """)
  end

  defp populate_dim_impact(stg) do
    Repo.query("""
      INSERT INTO dim_impact (skidding_code, hit_object_code, leave_carriageway_code, hit_object_off_code, first_impact_code)
      SELECT DISTINCT v_skid, v_hit, v_leave, v_hitoff, v_impact
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_impact d
        WHERE d.skidding_code = s.v_skid
          AND d.hit_object_code = s.v_hit
          AND d.leave_carriageway_code = s.v_leave
          AND d.hit_object_off_code = s.v_hitoff
          AND d.first_impact_code = s.v_impact
      )
    """)
  end

  defp populate_dim_person_from_vehicle(stg) do
    Repo.query("""
      INSERT INTO dim_person (sex_code, age_group_code)
      SELECT DISTINCT v_sex, v_agegroup
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_person d
        WHERE d.sex_code = s.v_sex AND d.age_group_code = s.v_agegroup
      )
    """)
  end

  defp populate_fact_vehicle(stg) do
    Repo.query("""
      INSERT INTO fact_vehicle (
        vehicle_id, collision_id, vehicle_type_key, manoeuvre_key, impact_key, driver_key,
        year, accident_ref, vehicle_ref, hit_and_run_code, foreign_registered
      )
      SELECT
        s.v_id, s.a_year || '-' || s.a_ref,
        dvt.vehicle_type_key, dm.manoeuvre_key, di.impact_key, dp.person_key,
        s.a_year, s.a_ref, s.v_id, s.v_hitr, s.v_forreg
      FROM #{stg} s
      LEFT JOIN dim_vehicle_type dvt
        ON dvt.type_code = s.v_type AND dvt.towing_code = s.v_tow
      LEFT JOIN dim_manoeuvre dm
        ON dm.manoeuvre_code = s.v_man AND dm.vehicle_location_code = s.v_loc
        AND dm.junction_location_code = s.v_junc
      LEFT JOIN dim_impact di
        ON di.skidding_code = s.v_skid AND di.hit_object_code = s.v_hit
        AND di.leave_carriageway_code = s.v_leave AND di.hit_object_off_code = s.v_hitoff
        AND di.first_impact_code = s.v_impact
      LEFT JOIN dim_person dp
        ON dp.sex_code = s.v_sex AND dp.age_group_code = s.v_agegroup
      WHERE NOT EXISTS (
        SELECT 1 FROM fact_vehicle f
        WHERE f.collision_id = s.a_year || '-' || s.a_ref AND f.vehicle_id = s.v_id
      )
    """)
  end

  # ---- casualty ----

  defp transform_casualty(stg) do
    with {:ok, _} <- run_step("dim_casualty_type", fn -> populate_dim_casualty_type(stg) end),
         {:ok, _} <-
           run_step("dim_person (casualty)", fn -> populate_dim_person_from_casualty(stg) end),
         {:ok, _} <- run_step("fact_casualty", fn -> populate_fact_casualty(stg) end) do
      {:ok, "casualty dimensions + facts populated"}
    end
  end

  defp populate_dim_casualty_type(stg) do
    Repo.query("""
      INSERT INTO dim_casualty_type (class_code, severity_code, severity_score, location_code, movement_code, pedestrian_injury_code)
      SELECT DISTINCT
        c_class, c_sever,
        CASE c_sever WHEN '1' THEN 3 WHEN '2' THEN 2 WHEN '3' THEN 1 ELSE 0 END,
        c_loc, c_move, c_pedinj
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_casualty_type d
        WHERE d.class_code = s.c_class
          AND d.severity_code = s.c_sever
          AND d.location_code = s.c_loc
          AND d.movement_code = s.c_move
          AND d.pedestrian_injury_code = s.c_pedinj
      )
    """)
  end

  defp populate_dim_person_from_casualty(stg) do
    Repo.query("""
      INSERT INTO dim_person (sex_code, age_group_code)
      SELECT DISTINCT c_sex, c_agegroup
      FROM #{stg} s
      WHERE NOT EXISTS (
        SELECT 1 FROM dim_person d
        WHERE d.sex_code = s.c_sex AND d.age_group_code = s.c_agegroup
      )
    """)
  end

  defp populate_fact_casualty(stg) do
    Repo.query("""
      INSERT INTO fact_casualty (
        casualty_id, collision_id, vehicle_id, casualty_type_key, person_key, vehicle_type_key,
        year, accident_ref, casualty_ref, severity_score, is_school_pupil, pcv_passenger
      )
      SELECT
        s.c_id, s.a_year || '-' || s.a_ref, s.v_id,
        dct.casualty_type_key, dp.person_key, dvt.vehicle_type_key,
        s.a_year, s.a_ref, s.c_id,
        CASE s.c_sever WHEN '1' THEN 3 WHEN '2' THEN 2 WHEN '3' THEN 1 ELSE 0 END,
        CASE WHEN s.c_school = '1' THEN TRUE ELSE FALSE END,
        s.c_pcv
      FROM #{stg} s
      LEFT JOIN dim_casualty_type dct
        ON dct.class_code = s.c_class AND dct.severity_code = s.c_sever
        AND dct.location_code = s.c_loc AND dct.movement_code = s.c_move
        AND dct.pedestrian_injury_code = s.c_pedinj
      LEFT JOIN dim_person dp
        ON dp.sex_code = s.c_sex AND dp.age_group_code = s.c_agegroup
      LEFT JOIN dim_vehicle_type dvt
        ON dvt.type_code = s.c_vtype AND dvt.towing_code = '-1'
      WHERE NOT EXISTS (
        SELECT 1 FROM fact_casualty f
        WHERE f.collision_id = s.a_year || '-' || s.a_ref AND f.casualty_id = s.c_id
      )
    """)
  end

  # ---- Helper: логирование каждого шага ----

  defp run_step(name, fun) do
    Logger.info("[ETL]   → #{name}...")
    start = System.monotonic_time(:millisecond)

    case fun.() do
      {:ok, %{num_rows: rows}} = result ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.info("[ETL]   ✓ #{name}: #{rows} rows (#{ms}ms)")
        result

      {:ok, _} = result ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.info("[ETL]   ✓ #{name}: done (#{ms}ms)")
        result

      {:error, reason} = error ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.error("[ETL]   ✗ #{name} failed after #{ms}ms: #{inspect(reason)}")
        error
    end
  end
end
