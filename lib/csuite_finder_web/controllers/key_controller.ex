defmodule CsuiteFinderWeb.KeyController do
  @moduledoc """
  Managing API keys, and getting back in when one is lost.

  We store only a hash of a key, so a lost key genuinely cannot be handed back —
  that is the point of hashing it. The defence is holding more than one: mint a
  spare while you have a working key, keep it somewhere safe, and losing the
  everyday one stops being an incident.
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

  defp label(value) when is_binary(value) and value != "", do: String.slice(value, 0, 60)
  defp label(_), do: "created #{Date.utc_today()}"
end
