defmodule CsuiteFinderWeb.FallbackController do
  use CsuiteFinderWeb, :controller

  def call(conn, {:error, :invalid_email}) do
    bad_request(conn, "invalid_email", "`email` must be a valid address, e.g. jane@acme.com.")
  end

  def call(conn, {:error, :invalid_domain}) do
    bad_request(conn, "invalid_domain", "`domain` must be a valid domain, e.g. acme.com.")
  end

  def call(conn, {:error, :invalid_department}) do
    bad_request(
      conn,
      "invalid_department",
      "`department` must be one of: " <>
        Enum.join(CsuiteFinder.Prospects.departments(), ", ") <> "."
    )
  end

  def call(conn, {:error, :invalid_name}) do
    bad_request(conn, "invalid_name", "`full_name` could not be parsed into a name.")
  end

  def call(conn, {:error, :missing_params, required}) do
    bad_request(conn, "missing_params", "Required: #{Enum.join(required, ", ")}.")
  end

  def call(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  def call(conn, {:error, reason}) do
    # The reason can carry an upstream provider's response verbatim — its name,
    # its error vocabulary, sometimes its quota. Log it, do not serve it.
    require Logger
    Logger.error("lookup failed: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: "lookup_failed",
      message: "The lookup could not be completed. Nothing was charged."
    })
  end

  defp bad_request(conn, error, message) do
    conn |> put_status(:bad_request) |> json(%{error: error, message: message})
  end
end
