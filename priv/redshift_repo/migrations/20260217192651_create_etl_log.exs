defmodule S3TestTask.RedshiftRepo.Migrations.CreateEtlLog do
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS etl_log (
      id BIGINT IDENTITY(1,1) PRIMARY KEY,
      filename VARCHAR(255) NOT NULL,
      staging_table VARCHAR(255),
      status VARCHAR(20) NOT NULL,
      message TEXT,
      rows_affected INT,
      duration_ms INT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS etl_log"
  end
end
