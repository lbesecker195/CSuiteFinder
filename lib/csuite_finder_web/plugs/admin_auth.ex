defmodule CsuiteFinderWeb.Plugs.AdminAuth do
  @moduledoc """
  Guards the admin dashboard with a single shared token.

  Two deliberate choices. The token is compared with a constant-time equality
  check, so the comparison cannot be used as an oracle to recover it a byte at a
  time. And if no token is configured the dashboard is **closed**, not open —
  the failure mode of a missing environment variable should be "nobody can see
  the metrics", never "everybody can".

  The token may arrive as `Authorization: Bearer`, `X-Admin-Token`, or a `token`
  query parameter, the last so the page can be opened from a browser address bar.
  """

  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case configured_token() do
      nil ->
        refuse(
          conn,
          503,
          "Admin dashboard is disabled. Set ADMIN_TOKEN to enable it."
        )

      expected ->
        if valid?(conn, expected) do
          conn
        else
          refuse(conn, 401, "Invalid or missing admin token.")
        end
    end
  end

  defp valid?(conn, expected) do
    case presented(conn) do
      nil -> false
      token -> Plug.Crypto.secure_compare(token, expected)
    end
  end

  defp presented(conn) do
    header =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> String.trim(token)
        ["bearer " <> token | _] -> String.trim(token)
        _ -> nil
      end

    header || List.first(get_req_header(conn, "x-admin-token")) || query_token(conn)
  end

  defp query_token(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["token"] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp configured_token do
    case Application.get_env(:csuite_finder, :admin_token) || System.get_env("ADMIN_TOKEN") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Answer in the format the caller asked for: JSON for the API, plain text for
  # a browser that wandered in.
  defp refuse(conn, status, message) do
    conn =
      if json?(conn) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{error: "unauthorized", message: message}))
      else
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(status, message <> "\n")
      end

    halt(conn)
  end

  defp json?(conn) do
    String.ends_with?(conn.request_path, ".json") or
      Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "json"))
  end
end
