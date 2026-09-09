defmodule CsuiteFinderWeb.Plugs.ApiAuth do
  @moduledoc """
  API-key authentication.

  The key is read from `Authorization: Bearer <key>` or `X-API-Key`. Set
  `config :csuite_finder, :require_api_key, false` to run the API open, which is
  only appropriate for local development — it is on by default so a deployment
  cannot accidentally serve paid lookups to anyone who finds the URL.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias CsuiteFinder.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_key(conn) do
      nil ->
        if required?() do
          unauthorized(conn, "Missing API key. Send `Authorization: Bearer <key>`.")
        else
          assign(conn, :account, nil) |> assign(:api_key, nil)
        end

      key ->
        case Accounts.authenticate(key) do
          {:ok, account, api_key} ->
            conn |> assign(:account, account) |> assign(:api_key, api_key)

          {:error, :suspended} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "account_suspended"})
            |> halt()

          {:error, :invalid_key} ->
            unauthorized(conn, "Invalid API key.")
        end
    end
  end

  defp extract_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key | _] -> String.trim(key)
      ["bearer " <> key | _] -> String.trim(key)
      _ -> conn |> get_req_header("x-api-key") |> List.first()
    end
  end

  defp required?, do: Application.get_env(:csuite_finder, :require_api_key, true)

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized", message: message})
    |> halt()
  end
end
