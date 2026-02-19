defmodule S3TestTaskWeb.UploadLive.Index do
  use S3TestTaskWeb, :live_view

  alias S3TestTask.Utils.S3Uploader
  alias S3TestTask.Utils.RedshiftLoader
  alias S3TestTask.Utils.Transformer
  alias S3TestTask.Utils.EtlLog

  @etl_suffixes [
    "collision2017-2022.csv",
    "vehicle2017-2022.csv",
    "casualty2017-2022.csv",
    "vehicle-index.csv"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:uploaded_files, [])
     |> assign(:s3_files, load_s3_files())
     |> assign(:loading_file, nil)
     |> assign(:etl_status, load_etl_statuses())
     |> assign(:etl_task, nil)
     |> assign(:staging_tables, %{})
     |> assign(:errors, [])
     |> allow_upload(:csv,
       accept: ~w(.csv),
       max_entries: 5,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", _params, socket) do
    {uploaded, errors} =
      consume_uploaded_entries(socket, :csv, fn %{path: path}, entry ->
        case S3Uploader.upload_file(path, entry.client_name) do
          {:ok, result} ->
            {:ok, %{name: entry.client_name, url: result.url, key: result.key}}

          {:error, reason} ->
            {:postpone, "Failed to upload #{entry.client_name}: #{inspect(reason)}"}
        end
      end)
      |> Enum.split_with(&is_map/1)

    {:noreply,
     socket
     |> update(:uploaded_files, &(&1 ++ uploaded))
     |> assign(:s3_files, load_s3_files())
     |> assign(:errors, errors)
     |> put_flash(:info, "#{length(uploaded)} file(s) uploaded successfully")}
  end

  @impl true
  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :csv, ref)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :s3_files, load_s3_files())}
  end

  @impl true
  def handle_event("load_to_redshift", %{"key" => key, "name" => name}, socket) do
    socket = assign(socket, :loading_file, key)
    parent = self()

    Task.start(fn ->
      result = RedshiftLoader.load_file(key)
      send(parent, {:redshift_result, key, name, result})
    end)

    {:noreply, put_flash(socket, :info, "Loading #{name} to Redshift...")}
  end

  @impl true
  def handle_info({:redshift_result, _key, name, result}, socket) do
    socket = assign(socket, :loading_file, nil)

    case result do
      {:ok, %{table: table}} ->
        staging_tables = Map.put(socket.assigns.staging_tables, name, table)

        {:noreply,
         socket
         |> assign(:staging_tables, staging_tables)
         |> put_flash(:info, "Loaded to table: #{table}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("transform", %{"name" => name}, socket) do
    case Map.get(socket.assigns.staging_tables, name) do
      nil ->
        {:noreply, put_flash(socket, :error, "First load #{name} to Redshift")}

      table ->
        etl_status = Map.put(socket.assigns.etl_status, name, :loading)
        socket = assign(socket, :etl_status, etl_status)
        parent = self()

        Task.start(fn ->
          result = Transformer.transform(name, table)
          send(parent, {:transform_result, name, result})
        end)

        {:noreply, put_flash(socket, :info, "Transforming #{name} → Star Schema...")}
    end
  end

  @impl true
  def handle_info({:transform_result, name, result}, socket) do
    {status, flash} =
      case result do
        {:ok, msg} -> {{:ok, msg}, {:info, "✅ #{name}: #{msg}"}}
        {:error, reason} -> {{:error, reason}, {:error, "❌ #{name}: #{inspect(reason)}"}}
      end

    etl_status = Map.put(socket.assigns.etl_status, name, status)

    {:noreply,
     socket
     |> assign(:etl_status, etl_status)
     |> put_flash(elem(flash, 0), elem(flash, 1))}
  end

  defp load_s3_files do
    case S3Uploader.list_files() do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  def etl_transformable?(name) do
    Enum.any?(@etl_suffixes, &String.ends_with?(name, &1))
  end

  def has_staging_table?(staging_tables, name) do
    Map.has_key?(staging_tables, name)
  end

  defp load_etl_statuses do
    EtlLog.get_status_map()
    |> Map.new(fn {filename, %{status: status, message: msg}} ->
      case status do
        "success" -> {filename, {:ok, msg}}
        "error" -> {filename, {:error, msg}}
      end
    end)
  end

  def error_to_string(:too_large), do: "File is too large (max 50MB)"
  def error_to_string(:not_accepted), do: "Only CSV files are accepted"
  def error_to_string(:too_many_files), do: "Maximum 5 files allowed"
  def error_to_string(err), do: inspect(err)

  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 2)} MB"
end
