defmodule CsuiteFinderWeb.KeyController do
  @moduledoc """
  Managing API keys, and getting back in when one is lost.

  We store only a hash of a key, so a lost key genuinely cannot be handed back —
  that is the point of hashing it. What can be done, and what these routes do,
  is prove ownership of the account by email and issue a *replacement*. The
  balance was never at risk; only the credential was.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Accounts

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "GET /csuitefinder/keys — the account's keys (never their values)"
  def index(conn, _params) do
    keys =
      conn.assigns.account
      |> Accounts.list_api_keys()
      |> Enum.map(fn key ->
        %{
          id: key.id,
          prefix: key.prefix,
          label: key.label,
          created_at: key.inserted_at,
          last_used_at: key.last_used_at,
          revoked: not is_nil(key.revoked_at),
          # The key currently making this request, so the UI never invites
          # someone to revoke the credential they are holding.
          current: key.id == conn.assigns.api_key.id
        }
      end)

    json(conn, %{keys: keys})
  end

  @doc "POST /csuitefinder/keys — mint an additional key"
  def create(conn, params) do
    {:ok, plaintext, key} =
      Accounts.create_api_key(conn.assigns.account, label(params["label"]))

    conn
    |> put_status(:created)
    |> json(%{
      id: key.id,
      api_key: plaintext,
      label: key.label,
      notice: "Store this now — it is shown once and cannot be recovered."
    })
  end

  @doc "DELETE /csuitefinder/keys/:id — revoke a key"
  def delete(conn, %{"id" => id}) do
    account = conn.assigns.account

    cond do
      to_string(conn.assigns.api_key.id) == to_string(id) ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "cannot_revoke_current_key",
          message: "That is the key you are signed in with. Create another first."
        })

      key = Accounts.get_api_key(account, id) ->
        {:ok, _} = Accounts.revoke_api_key(key)
        json(conn, %{id: key.id, revoked: true})

      true ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  @doc """
  POST /csuitefinder/keys/recover — email a link that issues a new key.

  Unauthenticated by necessity: the caller has no key. The response is the same
  whether or not the address is registered, so this cannot be used to discover
  which emails have accounts.
  """
  def recover(conn, params) do
    with {:ok, email} <- require_email(params) do
      link = fn token ->
        "#{base_url(conn)}/account?recover=#{URI.encode_www_form(token)}"
      end

      case Accounts.request_key_recovery(email, link) do
        {:ok, :sent} ->
          json(conn, %{
            status: "sent",
            message:
              "If that address has an account, a link to issue a new key is on its way. " <>
                "It expires in #{Accounts.recovery_valid_minutes()} minutes."
          })

        {:error, :mail_not_configured} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{
            error: "email_not_configured",
            message: "Key recovery by email is not switched on for this deployment."
          })
      end
    end
  end

  @doc "POST /csuitefinder/keys/issue — redeem a recovery token for a new key"
  def issue(conn, %{"token" => token}) do
    case Accounts.issue_key_from_recovery(token) do
      {:ok, account, plaintext} ->
        json(conn, %{
          email: account.email,
          api_key: plaintext,
          token_balance: account.token_balance,
          notice: "Store this now — it is shown once and cannot be recovered."
        })

      {:error, :expired} ->
        conn
        |> put_status(:gone)
        |> json(%{error: "link_expired", message: "That link has expired. Request another."})

      {:error, :invalid} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: "link_invalid",
          message: "That link is not valid — it may already have been used."
        })
    end
  end

  def issue(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "missing token"})

  defp require_email(params) do
    case params["email"] do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :missing_params, ["email"]}, else: {:ok, trimmed}

      _ ->
        {:error, :missing_params, ["email"]}
    end
  end

  defp label(value) when is_binary(value) and value != "", do: String.slice(value, 0, 60)
  defp label(_), do: "created #{Date.utc_today()}"

  defp base_url(conn) do
    Application.get_env(:csuite_finder, :public_base_url) ||
      "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"
end
