defmodule CsuiteFinderWeb.SessionController do
  @moduledoc """
  Signing in with a password, for people rather than programs.

  The API is key-authenticated and stays that way. This exists because a person
  should not have to keep a 44-character secret on a clipboard to look at their
  own balance — they sign in and get a session token, which expires on its own.

  Nothing here is a cookie. The token goes back in the response, the browser
  keeps it exactly as it kept a pasted key, and every other endpoint carries on
  taking a bearer token and nothing else.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Accounts

  action_fallback CsuiteFinderWeb.FallbackController

  @doc """
  POST /csuitefinder/login

  Answers the same way to an unknown address and a wrong password, and takes the
  same time over it. Anything else is a way to find out who has an account.
  """
  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.login(email, password) do
      {:ok, account, token, expires_at} ->
        json(conn, %{
          token: token,
          expires_at: expires_at,
          email: account.email,
          audience: account.audience,
          notice:
            "This is a browser session, not your API key. It expires on its own; " <>
              "your key is unaffected."
        })

      {:error, :locked} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: "too_many_attempts",
          message: "Too many failed sign-ins. Try again in a few minutes."
        })

      {:error, :suspended} ->
        conn |> put_status(:forbidden) |> json(%{error: "suspended"})

      {:error, :invalid_login} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: "invalid_login",
          message: "That email and password do not match an account."
        })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_params", message: "Send `email` and `password`."})
  end

  @doc """
  POST /csuitefinder/password — set or change the password, authenticated by key
  or by an existing session.

  This is also the recovery path, and the only one: there is no mail server to
  send a reset through, so someone who has forgotten their password signs in
  with their API key and sets a new one. The page says so before it asks.
  """
  def set_password(conn, %{"password" => password}) do
    case conn.assigns[:account] do
      nil ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      account ->
        case Accounts.set_password(account, password) do
          {:ok, _account} ->
            json(conn, %{
              ok: true,
              message: "Password set. You can sign in with your email from now on."
            })

          {:error, :password_too_short} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "password_too_short",
              message:
                "Use at least #{Accounts.min_password_length()} characters. " <>
                  "Length is the only rule — a longer phrase beats a short puzzle."
            })

          {:error, _} ->
            conn |> put_status(:bad_request) |> json(%{error: "invalid"})
        end
    end
  end

  def set_password(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_params", message: "Send `password`."})
  end

  @doc "POST /csuitefinder/logout — end this session. The API key is untouched."
  def delete(conn, _params) do
    case conn.assigns[:api_key] do
      nil ->
        json(conn, %{ok: true})

      key ->
        Accounts.end_session(key)
        json(conn, %{ok: true})
    end
  end
end
