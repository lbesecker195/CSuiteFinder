defmodule CsuiteFinder.Ssa do
  @moduledoc """
  Usage analytics for the half of the product a browser never sees.

  GA4 measures people on the website. It cannot see an agent that read
  `llms.txt` and started calling the API, which is how this service is meant to
  be used — so the busiest customers have been invisible in the numbers.
  SeriouslySimpleAnalytics fills that gap: a URL fetch per event, no SDK, no
  key, no body.

  ## What may be sent, and why the list is short

  Their own documentation puts it plainly: parameters travel in a URL and are
  written to the logs of every proxy in between. So this module does not send
  whatever it is handed. It sends the keys in `@allowed` and silently drops
  everything else.

  What that excludes is the point. Not the address being looked up, not the
  person's name, not the company domain — a competitor's domain list is the
  customer's business, not ours to broadcast — not an account id, not an email,
  and obviously no API key. What is left is shape rather than content: which
  endpoint, whether the cache answered, whether anything was found.

  An allowlist rather than a denylist because the failure modes are not
  symmetric: a forgotten denylist entry leaks customer data to a third party,
  while a forgotten allowlist entry loses a statistic.

  ## Failure is not the caller's problem

  Every ping is fire-and-forget in an unlinked task with a short timeout. The
  analytics service being slow, down, or wrong must never be visible in a
  customer's lookup — a telemetry call that can fail a paid request is worse
  than no telemetry.
  """

  require Logger

  @endpoint "https://seriouslysimpleanalytics.com/api/ping"
  @timeout 2_000

  # Shape, never content. See the moduledoc.
  @allowed ~w(endpoint cached found audience outcome units)a

  @doc """
  Record one event. Returns immediately and never raises.

  `attrs` is filtered against the allowlist before anything leaves the machine.
  """
  @spec ping(String.t(), keyword() | map()) :: :ok
  def ping(event, attrs \\ []) do
    case uid() do
      nil ->
        :ok

      uid ->
        query = build(uid, event, attrs)

        Task.start(fn ->
          try do
            Req.get(url: @endpoint, params: query, receive_timeout: @timeout, retry: false)
          rescue
            error ->
              Logger.debug("ssa ping failed: #{Exception.message(error)}")
          catch
            _, _ -> :ok
          end
        end)

        :ok
    end
  end

  @doc """
  The parameters a ping would carry. Exposed so a test can assert on what leaves
  rather than on what was passed in — which is the only version of that
  assertion worth having.
  """
  @spec build(String.t(), String.t(), keyword() | map()) :: keyword()
  def build(uid, event, attrs) do
    safe =
      attrs
      |> Enum.map(fn {k, v} -> {to_atom(k), v} end)
      |> Enum.filter(fn {k, v} -> k in @allowed and not is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)

    [uid: uid, type: "ai", project: project(), event: event] ++ safe
  end

  @doc "The keys a ping is allowed to carry."
  @spec allowed() :: [atom()]
  def allowed, do: @allowed

  # Anything not already an atom in the allowlist stays a string, and a string
  # never matches, so an unexpected key is dropped rather than creating an atom
  # from caller-supplied input.
  defp to_atom(key) when is_atom(key), do: key

  defp to_atom(key) when is_binary(key) do
    Enum.find(@allowed, key, fn allowed -> Atom.to_string(allowed) == key end)
  end

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])

  @doc "The account events are recorded against, or nil when this is switched off."
  @spec uid() :: String.t() | nil
  def uid do
    case config()[:uid] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc "The project name events are filed under."
  @spec project() :: String.t()
  def project, do: config()[:project] || "CSuiteFinder"

  @doc "Is agent-side analytics switched on here?"
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(uid())
end
