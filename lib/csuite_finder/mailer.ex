defmodule CsuiteFinder.Mailer do
  @moduledoc """
  Outbound email, used for one thing: getting a customer back into an account
  whose key they no longer have.

  Optional, like PayPal. With no SMTP settings the adapter is a local sink and
  `configured?/0` reports false, so the recovery flow can say "email is not
  switched on here" instead of silently accepting a request and never sending
  anything — a silent no-op is the failure mode that leaves someone waiting for
  a mail that was never going to arrive.
  """
  use Swoosh.Mailer, otp_app: :csuite_finder

  @doc "Is a real mail transport configured in this environment?"
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:csuite_finder, __MODULE__, [])[:adapter] do
      Swoosh.Adapters.SMTP -> true
      nil -> false
      Swoosh.Adapters.Local -> false
      _other -> true
    end
  end
end
