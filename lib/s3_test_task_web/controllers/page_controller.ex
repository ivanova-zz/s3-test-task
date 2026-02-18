defmodule S3TestTaskWeb.PageController do
  use S3TestTaskWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
