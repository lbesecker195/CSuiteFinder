defmodule CsuiteFinder.ReleaseTest do
  @moduledoc """
  Operator tasks must not start the web server.

  These run on a live box, and the documented way to get the database
  credentials into the shell also exports `PHX_SERVER=true` — the same file
  configures the service. Inheriting it once cost a password reset: the task
  booted a second endpoint, failed to bind the port the running service held,
  and died before it reached the database.
  """

  use CsuiteFinder.DataCase, async: false

  import ExUnit.CaptureIO

  alias CsuiteFinder.Release

  @endpoint_key CsuiteFinderWeb.Endpoint

  setup do
    original = Application.get_env(:csuite_finder, @endpoint_key, [])
    phx_server = System.get_env("PHX_SERVER")

    on_exit(fn ->
      Application.put_env(:csuite_finder, @endpoint_key, original)

      if phx_server,
        do: System.put_env("PHX_SERVER", phx_server),
        else: System.delete_env("PHX_SERVER")
    end)

    :ok
  end

  describe "a task started with PHX_SERVER set" do
    test "leaves the endpoint switched off" do
      # Exactly the state `. /etc/csuite-finder.env` puts the shell in.
      System.put_env("PHX_SERVER", "true")

      Application.put_env(
        :csuite_finder,
        @endpoint_key,
        Keyword.put(
          Application.get_env(:csuite_finder, @endpoint_key, []),
          :server,
          true
        )
      )

      # Any task will do; this one reaches the database and reports honestly.
      capture_io(fn ->
        assert Release.set_password("nobody-at-all@example.com", "a-long-enough-one") == :error
      end)

      refute Application.get_env(:csuite_finder, @endpoint_key)[:server],
             "an operator task re-enabled the web server; on a live box it cannot bind the port"
    end

    test "and still does the work it was asked to do" do
      System.put_env("PHX_SERVER", "true")

      {:ok, %{account: account}} =
        CsuiteFinder.Accounts.register(%{email: "release-task@example.com"})

      output =
        capture_io(fn ->
          assert Release.set_password(account.email, "a-long-enough-one") == :ok
        end)

      assert output =~ "Password set"
      # login/2 hands back a session as well as the account.
      assert {:ok, _account, _session, _expires} =
               CsuiteFinder.Accounts.login(account.email, "a-long-enough-one")
    end
  end
end
