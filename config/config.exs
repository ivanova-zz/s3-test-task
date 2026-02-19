# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :s3_test_task,
  ecto_repos: [S3TestTask.RedshiftRepo],
  generators: [timestamp_type: :utc_datetime]

config :s3_test_task, S3TestTask.RedshiftRepo,
  hostname: System.get_env("REDSHIFT_HOST"),
  port: 5439,
  database: System.get_env("REDSHIFT_DATABASE", "dev"),
  username: System.get_env("REDSHIFT_USER"),
  password: System.get_env("REDSHIFT_PASSWORD"),
  ssl: true,
  ssl_opts: [verify: :verify_none],
  pool_size: 5,
  migration_source: "schema_migrations",
  migration_lock: false,
  show_sensitive_data_on_connection_error: true

# Configure the endpoint
config :s3_test_task, S3TestTaskWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: S3TestTaskWeb.ErrorHTML, json: S3TestTaskWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: S3TestTask.PubSub,
  live_view: [signing_salt: "HKaTiAdL"]

config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: "eu-central-1"

config :s3_test_task,
  s3_bucket: System.get_env("S3_BUCKET", "my-bucket"),
  redshift_workgroup: System.get_env("REDSHIFT_WORKGROUP", "your-workgroup-name"),
  redshift_database: System.get_env("REDSHIFT_DATABASE", "dev"),
  redshift_iam_role: System.get_env("REDSHIFT_IAM_ROLE", "test")

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :s3_test_task, S3TestTask.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  s3_test_task: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  s3_test_task: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
