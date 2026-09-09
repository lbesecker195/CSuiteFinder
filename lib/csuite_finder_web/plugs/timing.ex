defmodule CsuiteFinderWeb.Plugs.Timing do
  @moduledoc """
  Stamps when a request began, so the metering can record how long the caller
  actually waited.

  Monotonic time, not wall-clock: a clock adjustment mid-request would otherwise
  produce a negative or wildly wrong duration.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.assign(conn, :started_at, System.monotonic_time(:millisecond))
  end

  @doc "Milliseconds since the request started, or nil if it was never stamped."
  @spec elapsed_ms(Plug.Conn.t()) :: non_neg_integer() | nil
  def elapsed_ms(%Plug.Conn{assigns: %{started_at: started}}),
    do: System.monotonic_time(:millisecond) - started

  def elapsed_ms(_conn), do: nil
end
