defmodule CsuiteFinderWeb.CacheBodyReader do
  @moduledoc """
  Keeps the raw request body so a webhook signature can be checked against it.

  Stripe signs the exact bytes it sent. `Plug.Parsers` consumes the body to
  build `conn.params`, and re-encoding those params produces different bytes —
  key order and number formatting are both free to change — so the hash would
  never match. This reads the body, hands it to the parser as normal, and stashes
  the original under `:raw_body`.

  Only the webhook path is cached. Every other request drops the bytes as soon
  as they are parsed, because holding the body of an arbitrary upload in memory
  for the life of a request is a way to be knocked over by a large one.
  """

  @cached ["/csuitefinder/billing/webhook"]

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    if conn.request_path in @cached do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      {:ok, body, conn}
    end
  end
end
