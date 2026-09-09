defmodule CsuiteFinder.Mail.KeyRecovery do
  @moduledoc """
  The one email this service sends: a link that mints a replacement API key.

  The link carries a signed, expiring token rather than the key itself — a key
  emailed in plaintext lives in the recipient's mailbox forever, and in whatever
  else has read access to it.
  """

  import Swoosh.Email

  alias CsuiteFinder.Accounts.Account

  @doc "Build the recovery email for `account`, pointing at `url`."
  @spec build(Account.t(), String.t(), pos_integer()) :: Swoosh.Email.t()
  def build(%Account{} = account, url, valid_minutes) do
    new()
    |> to({account.name || account.email, account.email})
    |> from({from_name(), from_address()})
    |> subject("Your CSuiteFinder API key")
    |> text_body("""
    Someone asked for a new API key for #{account.email}.

    Open this link to issue one. It works once and expires in #{valid_minutes} minutes:

    #{url}

    Your existing keys keep working until you revoke them, and your token
    balance is untouched either way.

    If this wasn't you, ignore this email — no key is issued unless the link is
    opened, and nothing about your account has changed.
    """)
    |> html_body("""
    <p>Someone asked for a new API key for <strong>#{account.email}</strong>.</p>
    <p><a href="#{url}">Issue a new API key</a></p>
    <p style="color:#6b6560;font-size:14px">
      This link works once and expires in #{valid_minutes} minutes. Your existing
      keys keep working until you revoke them, and your token balance is
      untouched either way.
    </p>
    <p style="color:#6b6560;font-size:14px">
      If this wasn't you, ignore this email — no key is issued unless the link is
      opened, and nothing about your account has changed.
    </p>
    """)
  end

  defp config, do: Application.get_env(:csuite_finder, CsuiteFinder.Mailer, [])
  defp from_address, do: config()[:from_address] || "no-reply@csuitefinder.com"
  defp from_name, do: config()[:from_name] || "CSuiteFinder"
end
