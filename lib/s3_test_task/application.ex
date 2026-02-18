defmodule S3TestTask.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      S3TestTaskWeb.Telemetry,
      S3TestTask.RedshiftRepo,
      #      S3TestTask.Repo,
      {DNSCluster, query: Application.get_env(:s3_test_task, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: S3TestTask.PubSub},
      # Start a worker by calling: S3TestTask.Worker.start_link(arg)
      # {S3TestTask.Worker, arg},
      # Start to serve requests, typically the last entry
      S3TestTaskWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: S3TestTask.Supervisor]
    result = Supervisor.start_link(children, opts)
    setup_redshift()
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    S3TestTaskWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_redshift do
    S3TestTask.RedshiftRepo.query("""
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version BIGINT NOT NULL,
        inserted_at TIMESTAMP WITHOUT TIME ZONE,
        PRIMARY KEY (version)
      )
    """)
  end
end
