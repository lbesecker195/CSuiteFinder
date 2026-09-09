defmodule CsuiteFinderWeb.KeyTest do
  @moduledoc """
  A key cannot be recovered — only a hash is stored. The defence is holding a
  spare, so these routes are the whole answer to "what if I lose it".
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Accounts, Fixtures}

  setup %{conn: conn} do
    {account, key} = Fixtures.account_with_key(tokens: 400)

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer " <> key), account: account, key: key}
  end

  describe "GET /csuitefinder/keys" do
    test "lists keys without ever exposing their values", %{conn: conn, key: key} do
      body = conn |> get(~p"/csuitefinder/keys") |> json_response(200)

      assert [k] = body["keys"]
      assert k["current"]
      refute k["revoked"]
      assert k["prefix"]
      # The prefix identifies it; the key itself is never sent back.
      refute String.contains?(Jason.encode!(body), key)
    end

    test "requires a key of its own", %{conn: conn} do
      conn
      |> delete_req_header("authorization")
      |> get(~p"/csuitefinder/keys")
      |> json_response(401)
    end
  end

  describe "POST /csuitefinder/keys" do
    test "mints an additional key that also works", %{conn: conn, account: account} do
      body = conn |> post(~p"/csuitefinder/keys", %{label: "ci"}) |> json_response(201)

      assert body["label"] == "ci"
      assert body["notice"] =~ "shown once"
      assert {:ok, same, _} = Accounts.authenticate(body["api_key"])
      assert same.id == account.id
      assert length(Accounts.list_api_keys(account)) == 2
    end

    test "the spare keeps working after the original is revoked", %{conn: conn, account: account} do
      # This is the whole point: a second key is what makes losing the first
      # survivable, since no one can hand the lost one back.
      spare = conn |> post(~p"/csuitefinder/keys", %{label: "spare"}) |> json_response(201)
      [original] = Enum.filter(Accounts.list_api_keys(account), &(&1.label != "spare"))

      spare_conn = put_req_header(build_conn(), "authorization", "Bearer " <> spare["api_key"])
      assert spare_conn |> delete(~p"/csuitefinder/keys/#{original.id}") |> json_response(200)

      assert {:ok, _, _} = Accounts.authenticate(spare["api_key"])
      assert spare_conn |> get(~p"/csuitefinder/billing/balance") |> json_response(200)
    end
  end

  describe "DELETE /csuitefinder/keys/:id" do
    test "refuses to revoke the key you are signed in with", %{conn: conn, account: account} do
      [current] = Accounts.list_api_keys(account)

      body = conn |> delete(~p"/csuitefinder/keys/#{current.id}") |> json_response(409)
      assert body["error"] == "cannot_revoke_current_key"
      # Locking yourself out would be unrecoverable, so it is simply not allowed.
      assert {:ok, _, _} =
               Accounts.authenticate(
                 conn
                 |> get_req_header("authorization")
                 |> hd()
                 |> String.replace("Bearer ", "")
               )
    end

    test "revokes another key, which then stops working", %{conn: conn} do
      other = conn |> post(~p"/csuitefinder/keys", %{}) |> json_response(201)

      assert conn |> delete(~p"/csuitefinder/keys/#{other["id"]}") |> json_response(200)
      assert {:error, :invalid_key} = Accounts.authenticate(other["api_key"])
    end

    test "cannot reach another account's key", %{conn: conn} do
      {other_account, _} = Fixtures.account_with_key()
      [victim] = Accounts.list_api_keys(other_account)

      assert conn |> delete(~p"/csuitefinder/keys/#{victim.id}") |> json_response(404)
      assert Enum.all?(Accounts.list_api_keys(other_account), &is_nil(&1.revoked_at))
    end

    test "a non-numeric id is a 404, not a crash", %{conn: conn} do
      conn |> delete(~p"/csuitefinder/keys/not-an-id") |> json_response(404)
    end
  end

  describe "recovery is deliberately absent" do
    test "there is no route that emails a key back", %{conn: conn} do
      # Storing the plaintext so it could be resent would mean one database
      # leak hands over every customer's key and the balance behind it.
      assert conn |> post("/csuitefinder/keys/recover", %{email: "x@y.com"}) |> response(404)
      assert conn |> post("/csuitefinder/keys/issue", %{token: "anything"}) |> response(404)
    end
  end
end
