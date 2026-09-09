defmodule CsuiteFinderWeb.KeyTest do
  use CsuiteFinderWeb.ConnCase, async: true

  import Swoosh.TestAssertions

  alias CsuiteFinder.{Accounts, Fixtures, Repo}

  describe "POST /csuitefinder/keys/recover" do
    test "emails a link when the address has an account", %{conn: conn} do
      {:ok, %{account: account}} = Accounts.register(%{email: "lost@company.com"})

      body =
        conn
        |> post(~p"/csuitefinder/keys/recover", %{email: "lost@company.com"})
        |> json_response(200)

      assert body["status"] == "sent"

      assert_email_sent(fn email ->
        assert {_, "lost@company.com"} = hd(email.to)
        assert email.subject =~ "API key"
        # The key itself must never be emailed — only a link that mints one.
        refute email.text_body =~ "csf_live_"
        assert email.text_body =~ "/account?recover="
      end)

      assert Repo.reload(account).key_recovery_at
    end

    test "answers identically for an address with no account", %{conn: conn} do
      body =
        conn
        |> post(~p"/csuitefinder/keys/recover", %{email: "nobody@nowhere.com"})
        |> json_response(200)

      # Same response, so this cannot be used to discover which emails are registered.
      assert body["status"] == "sent"
      assert_no_email_sent()
    end

    test "requires an email", %{conn: conn} do
      assert %{"error" => "missing_params"} =
               conn |> post(~p"/csuitefinder/keys/recover", %{}) |> json_response(400)
    end
  end

  describe "POST /csuitefinder/keys/issue" do
    setup %{conn: conn} do
      {:ok, %{account: account}} = Accounts.register(%{email: "lost@company.com"})
      post(conn, ~p"/csuitefinder/keys/recover", %{email: "lost@company.com"})

      token =
        receive do
          {:email, email} -> Regex.run(~r/recover=([^\s\)]+)/, email.text_body) |> List.last()
        after
          0 -> flunk("no recovery email captured")
        end

      {:ok, conn: conn, account: account, token: URI.decode_www_form(token)}
    end

    test "issues a working replacement key", %{conn: conn, token: token, account: account} do
      body = conn |> post(~p"/csuitefinder/keys/issue", %{token: token}) |> json_response(200)

      assert body["email"] == "lost@company.com"
      assert String.starts_with?(body["api_key"], "csf_live_")
      # The balance was never at risk — only the credential.
      assert body["token_balance"] == account.token_balance

      assert {:ok, recovered, _} = Accounts.authenticate(body["api_key"])
      assert recovered.id == account.id
    end

    test "the link works exactly once", %{conn: conn, token: token} do
      assert conn |> post(~p"/csuitefinder/keys/issue", %{token: token}) |> json_response(200)

      # A signed token alone would still verify here; clearing the stamp on the
      # account is what makes the replay fail.
      body = conn |> post(~p"/csuitefinder/keys/issue", %{token: token}) |> json_response(401)
      assert body["error"] == "link_invalid"
    end

    test "rejects a forged token", %{conn: conn} do
      body =
        conn
        |> post(~p"/csuitefinder/keys/issue", %{token: "not-a-real-token"})
        |> json_response(401)

      assert body["error"] == "link_invalid"
    end

    test "does not revoke the keys the account already had", %{
      conn: conn,
      token: token,
      account: account
    } do
      before = length(Accounts.list_api_keys(account))
      conn |> post(~p"/csuitefinder/keys/issue", %{token: token}) |> json_response(200)

      keys = Accounts.list_api_keys(account)
      assert length(keys) == before + 1
      assert Enum.all?(keys, &is_nil(&1.revoked_at))
    end
  end

  describe "key management" do
    setup %{conn: conn} do
      {account, key} = Fixtures.account_with_key(tokens: 400)

      {:ok,
       conn: put_req_header(conn, "authorization", "Bearer " <> key), account: account, key: key}
    end

    test "lists keys without ever exposing their values", %{conn: conn, key: key} do
      body = conn |> get(~p"/csuitefinder/keys") |> json_response(200)

      assert [k] = body["keys"]
      assert k["current"]
      refute k["revoked"]
      # Only the prefix, never the key.
      refute String.contains?(Jason.encode!(body), key)
    end

    test "mints an additional key that also works", %{conn: conn, account: account} do
      body = conn |> post(~p"/csuitefinder/keys", %{label: "ci"}) |> json_response(201)

      assert body["label"] == "ci"
      assert {:ok, same, _} = Accounts.authenticate(body["api_key"])
      assert same.id == account.id
      assert length(Accounts.list_api_keys(account)) == 2
    end

    test "refuses to revoke the key you are signed in with", %{conn: conn, account: account} do
      [current] = Accounts.list_api_keys(account)

      body = conn |> delete(~p"/csuitefinder/keys/#{current.id}") |> json_response(409)
      assert body["error"] == "cannot_revoke_current_key"
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
  end
end
