defmodule CsuiteFinderWeb.SessionTest do
  @moduledoc """
  Signing in with a password.

  Most of this is about the ways a login endpoint leaks or gives way, because
  adding one to a system that had only high-entropy keys is the moment those
  become possible.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Accounts
  alias CsuiteFinder.Accounts.{Account, ApiKey}
  alias CsuiteFinder.Repo

  @password "correct horse battery staple"

  defp registered(opts \\ []) do
    email = "user#{System.unique_integer([:positive])}@test.com"

    {:ok, %{account: account, api_key: key}} =
      Accounts.register(Map.merge(%{email: email, audience: "developer"}, Map.new(opts)))

    {account, key, email}
  end

  describe "setting a password" do
    test "is done with the API key, which is the only recovery path there is",
         %{conn: conn} do
      {_account, key, _email} = registered()

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> post(~p"/csuitefinder/password", %{password: @password})
        |> json_response(200)

      assert body["ok"]
    end

    test "refuses a short one, and says the rule is length", %{conn: conn} do
      {_account, key, _email} = registered()

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> post(~p"/csuitefinder/password", %{password: "short"})
        |> json_response(400)

      assert body["error"] == "password_too_short"
      assert body["message"] =~ "at least 8 characters"
    end

    test "is never stored in the clear" do
      {account, _key, _email} = registered(password: @password)
      stored = Repo.get!(Account, account.id)

      refute stored.password_hash == @password
      assert String.starts_with?(stored.password_hash, "$2b$")
    end

    test "can be set at registration", %{conn: conn} do
      email = "signup#{System.unique_integer([:positive])}@test.com"

      conn
      |> post(~p"/csuitefinder/register", %{email: email, password: @password})
      |> json_response(201)

      assert {:ok, _account, _token, _expires} = Accounts.login(email, @password)
    end
  end

  describe "signing in" do
    test "returns a session token, not the account's API key", %{conn: conn} do
      # We hold only a hash of the key and could not return it if we wanted to.
      # A separate token also means a browser session can expire without
      # touching the credential a script depends on.
      {_account, key, email} = registered(password: @password)

      body =
        conn
        |> post(~p"/csuitefinder/login", %{email: email, password: @password})
        |> json_response(200)

      assert String.starts_with?(body["token"], "csf_sess_")
      refute body["token"] == key
      assert body["expires_at"]
    end

    test "and that token works on the API", %{conn: conn} do
      {_account, _key, email} = registered(password: @password)

      token =
        conn
        |> post(~p"/csuitefinder/login", %{email: email, password: @password})
        |> json_response(200)
        |> Map.fetch!("token")

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/csuitefinder/billing/balance")
        |> json_response(200)

      assert body["email"] == email
    end

    test "answers the same to a wrong password and an unknown address", %{conn: conn} do
      # Anything else is a way to find out who has an account here.
      {_account, _key, email} = registered(password: @password)

      wrong =
        conn
        |> post(~p"/csuitefinder/login", %{email: email, password: "not the password"})
        |> json_response(401)

      unknown =
        build_conn()
        |> post(~p"/csuitefinder/login", %{email: "nobody@nowhere.test", password: @password})
        |> json_response(401)

      assert wrong == unknown
    end

    test "refuses an account that has no password", %{conn: conn} do
      {_account, _key, email} = registered()

      assert conn
             |> post(~p"/csuitefinder/login", %{email: email, password: @password})
             |> json_response(401)
    end
  end

  describe "guessing" do
    test "locks the account after five wrong tries", %{conn: conn} do
      {account, _key, email} = registered(password: @password)

      for _ <- 1..5 do
        build_conn()
        |> post(~p"/csuitefinder/login", %{email: email, password: "wrong"})
        |> json_response(401)
      end

      # Even the right password is refused now, and says why.
      body =
        conn
        |> post(~p"/csuitefinder/login", %{email: email, password: @password})
        |> json_response(429)

      assert body["error"] == "too_many_attempts"
      assert Repo.get!(Account, account.id).locked_until
    end

    test "a successful sign-in clears the count", %{conn: conn} do
      {account, _key, email} = registered(password: @password)

      for _ <- 1..3 do
        build_conn() |> post(~p"/csuitefinder/login", %{email: email, password: "wrong"})
      end

      conn
      |> post(~p"/csuitefinder/login", %{email: email, password: @password})
      |> json_response(200)

      assert Repo.get!(Account, account.id).failed_logins == 0
    end
  end

  describe "the account page" do
    test "offers a password sign-in and says there is no email reset", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ ~s|id="loginpassword"|
      assert html =~ ~s|id="signin-password"|
      # The one thing someone must know before they rely on a password here.
      assert html =~ "There is no email reset"
      assert html =~ "we will set a new one for you"
    end

    test "has no key-pasting sign-in left on it", %{conn: conn} do
      # The page is a person's door and takes a password. A key is what a
      # program carries; keeping both was two ways in to maintain and explain.
      html = conn |> get(~p"/account") |> html_response(200)

      refute html =~ ~s|id="signin"|
      refute html =~ "Have a key instead"
      refute html =~ "Paste it to see your balance"
    end

    test "never puts a password in the markup", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      # Password fields are inputs to be typed into, never values to render.
      refute html =~ ~r/type="password"[^>]*value="[^"]+"/
    end

    test "asks for a length rather than a puzzle", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ "at least 8 characters"
      assert html =~ "length is the only rule"
    end
  end

  describe "sessions end" do
    test "on their own, without anyone revoking them" do
      {account, _key, _email} = registered(password: @password)
      {token, _expires} = Accounts.start_session(account)

      assert {:ok, _account, _key} = Accounts.authenticate(token)

      # Wind it back past its expiry.
      Repo.get_by!(ApiKey, kind: "session", account_id: account.id)
      |> ApiKey.changeset(%{expires_at: DateTime.add(DateTime.utc_now(), -1)})
      |> Repo.update!()

      assert {:error, :invalid_key} = Accounts.authenticate(token)
    end

    test "and signing out does not touch the API key", %{conn: conn} do
      {_account, key, email} = registered(password: @password)

      token =
        conn
        |> post(~p"/csuitefinder/login", %{email: email, password: @password})
        |> json_response(200)
        |> Map.fetch!("token")

      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/csuitefinder/logout")
      |> json_response(200)

      assert {:error, :invalid_key} = Accounts.authenticate(token)
      assert {:ok, _account, _key} = Accounts.authenticate(key)
    end
  end
end
