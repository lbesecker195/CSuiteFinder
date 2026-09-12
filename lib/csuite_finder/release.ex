defmodule CsuiteFinder.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :csuite_finder

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Put credit on an account by hand, in whole dollars.

  For the cases a PayPal capture cannot cover: a customer paid another way, or
  someone is owed a refund of credit rather than money.

  It goes through `CsuiteFinder.Billing.credit/2` rather than an UPDATE, which
  is the point of it existing. Credit lives in two columns with different
  lifetimes, and a hand-written UPDATE into `granted_micro` would quietly hand
  someone a balance that expires at the end of the month. This always credits
  the purchased pool, which never expires — the same place a payment lands.

      bin/csuite_finder eval 'CsuiteFinder.Release.credit("me@example.com", 1000)'

  Prints the balance before and after, and refuses rather than guesses when the
  address is not on an account.
  """
  def credit(email, usd) when is_binary(email) and is_number(usd) and usd > 0 do
    start_app()

    email = String.downcase(String.trim(email))

    case CsuiteFinder.Repo.get_by(CsuiteFinder.Accounts.Account, email: email) do
      nil ->
        IO.puts("No account for #{email}. Nothing changed.")
        :error

      account ->
        before = CsuiteFinder.Billing.available_micro(account)

        {:ok, updated} =
          CsuiteFinder.Billing.credit(account, CsuiteFinder.Billing.Pricing.micro(usd))

        IO.puts("""
        #{email}
          before   $#{money(before)}
          credited $#{money_usd(usd)}
          after    $#{money(CsuiteFinder.Billing.available_micro(updated))} \
        (purchased $#{money(updated.balance_micro)}, \
        granted $#{money(CsuiteFinder.Billing.live_grant_micro(updated))})
        """)

        {:ok, updated}
    end
  end

  @doc """
  Set an account's password from the server.

  The only reset path there is: no mail server means no reset link, so someone
  locked out of the account page needs an operator. Takes the password as an
  argument rather than reading it from anywhere, so it never lands in the repo —
  and mind that it lands in your shell history instead.

      bin/csuite_finder rpc 'CsuiteFinder.Release.set_password("you@example.com", "…")'

  Also clears any lockout, which is usually why someone is asking.
  """
  def set_password(email, password) when is_binary(email) and is_binary(password) do
    start_app()

    email = String.downcase(String.trim(email))

    case CsuiteFinder.Repo.get_by(CsuiteFinder.Accounts.Account, email: email) do
      nil ->
        IO.puts("No account for #{email}. Nothing changed.")
        :error

      account ->
        case CsuiteFinder.Accounts.set_password(account, password) do
          {:ok, _account} ->
            IO.puts("Password set for #{email}. Any lockout is cleared.")
            :ok

          {:error, :password_too_short} ->
            IO.puts(
              "Too short — at least #{CsuiteFinder.Accounts.min_password_length()} characters."
            )

            :error

          {:error, reason} ->
            IO.puts("Could not set it: #{inspect(reason)}")
            :error
        end
    end
  end

  # Interpolating the float directly printed a $1,000 credit as "$1.0e3", which
  # is the single line an operator reads to confirm they credited the right
  # amount. Fixed decimals, and a thousands separator so four figures are
  # readable at a glance.
  defp money(micro), do: money_usd(CsuiteFinder.Billing.Pricing.usd(micro))

  defp money_usd(usd) when is_number(usd) do
    # `usd / 1` because this is called with both an integer (the amount asked
    # for) and a float (a balance read back), and float_to_binary takes only one
    # of those.
    [whole, cents] =
      usd |> Kernel./(1) |> :erlang.float_to_binary(decimals: 2) |> String.split(".")

    delimited =
      whole
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    delimited <> "." <> cents
  end

  # Starting the app for a one-off task must never start the web server.
  #
  # Every one of these tasks is run on a live box, and the documented way to get
  # the database credentials into the shell is `. /etc/csuite-finder.env` — which
  # also exports `PHX_SERVER=true`, because the same file configures the service.
  # `eval` then inherits it, boots a second endpoint, fails to bind the port the
  # running service already holds, and takes the whole task down with it before it
  # reaches the database. The operator sees a page of supervisor output and no
  # hint that the task itself was fine.
  #
  # So the endpoint is switched off here rather than relied upon to be off.
  # Overriding the env is the only thing that works: `PHX_SERVER=` does not,
  # since `System.get_env/1` returns "" for it and every string is truthy.
  defp start_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)

    Application.put_env(
      @app,
      CsuiteFinderWeb.Endpoint,
      @app
      |> Application.get_env(CsuiteFinderWeb.Endpoint, [])
      |> Keyword.put(:server, false)
    )

    Application.ensure_all_started(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
