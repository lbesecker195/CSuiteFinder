defmodule CsuiteFinderWeb.Prefill do
  @moduledoc """
  Values a link can carry in its query string, made safe to print.

  A campaign link arrives as `?name=…&email=…` so the person who opens it sees
  their own details already filled in — in the signup field, and as their own
  row in the sample sheet.

  Both values are written by whoever built the URL, which is anybody. These
  templates are plain EEx and escape nothing of their own, so a value that
  reached them unchecked would land in the page exactly as given. Two things
  stop that: each value has to look like the thing it claims to be before it is
  used at all, and it is escaped afterwards regardless. The shape check alone
  would do; the escape is there because "the regex is tight" is a bad thing to
  be relying on the day someone loosens the regex.
  """

  # Deliberately narrow. A real name is letters, spaces and the handful of marks
  # that appear inside surnames — no angle brackets, quotes, ampersands or
  # anything else that changes meaning inside markup.
  @name ~r/^[\p{L}][\p{L} .'\-]{0,58}$/u
  @email ~r/^[^\s@<>"'&]+@[^\s@<>"'&]+\.[^\s@<>"'&]+$/

  @doc "An address from the query string, escaped, or nil."
  @spec email(term()) :: String.t() | nil
  def email(value), do: clean(value, @email, 254)

  @doc "A person's name from the query string, escaped, or nil."
  @spec name(term()) :: String.t() | nil
  def name(value), do: clean(value, @name, 60)

  defp clean(value, pattern, limit) when is_binary(value) do
    trimmed = value |> String.trim() |> String.slice(0, limit)

    if Regex.match?(pattern, trimmed), do: Plug.HTML.html_escape(trimmed), else: nil
  end

  defp clean(_value, _pattern, _limit), do: nil
end
