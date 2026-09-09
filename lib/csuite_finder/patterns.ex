defmodule CsuiteFinder.Patterns do
  @moduledoc """
  The email-pattern language: parsing what the provider gives us, applying a
  pattern to a name, and deriving a pattern back out of a known address.

  We keep patterns in our own canonical token form (`{first}.{last}`) rather
  than the provider's (`[F].[L]`) so a second provider with different notation
  can feed the same cache.
  """

  alias CsuiteFinder.Names

  @doc """
  Convert The Companies API notation into our canonical form.

      "[F].[L]"  -> "{first}.{last}"
      "[F1][L]"  -> "{f}{last}"
      "[F]"      -> "{first}"

  `[F2]` (a two-character prefix) becomes `{first:2}`.
  """
  @spec from_provider(String.t()) :: {:ok, String.t()} | {:error, :unsupported}
  def from_provider(pattern) when is_binary(pattern) do
    converted =
      Regex.replace(~r/\[([FLM])(\d*)\]/, pattern, fn _full, letter, count ->
        base =
          case letter do
            "F" -> "first"
            "L" -> "last"
            "M" -> "middle"
          end

        case count do
          "" -> "{#{base}}"
          "1" -> "{#{String.first(base)}}"
          n -> "{#{base}:#{n}}"
        end
      end)

    # Anything still carrying a bracket used a token we do not model; refusing
    # here is better than silently building a wrong address.
    if String.contains?(converted, ["[", "]"]) do
      {:error, :unsupported}
    else
      {:ok, converted}
    end
  end

  def from_provider(_), do: {:error, :unsupported}

  @doc """
  Apply a canonical pattern to a name, returning the local-part.

  Returns `{:error, :missing_part}` when the pattern needs a name part we do not
  have — a `{last}` pattern against a mononym, for instance.
  """
  @spec apply_pattern(String.t(), map()) :: {:ok, String.t()} | {:error, :missing_part}
  def apply_pattern(pattern, parts) do
    result =
      Regex.replace(~r/\{([a-z]+)(?::(\d+))?\}/, pattern, fn _full, token, count ->
        value = resolve_token(token, parts)

        cond do
          value in [nil, ""] -> "\0"
          count == "" -> value
          true -> String.slice(value, 0, String.to_integer(count))
        end
      end)

    if String.contains?(result, "\0") do
      {:error, :missing_part}
    else
      {:ok, sanitize(result)}
    end
  end

  defp resolve_token("first", p), do: p[:first]
  defp resolve_token("last", p), do: p[:last]
  defp resolve_token("middle", p), do: p[:middle]
  defp resolve_token("f", p), do: initial(p[:first])
  defp resolve_token("l", p), do: initial(p[:last])
  defp resolve_token("m", p), do: initial(p[:middle])
  defp resolve_token(_, _), do: nil

  defp initial(nil), do: nil
  defp initial(""), do: nil
  defp initial(value), do: String.first(value)

  # Local-parts are ASCII and carry no spaces or apostrophes: O'Brien -> obrien.
  defp sanitize(local) do
    local
    |> Names.deaccent()
    |> String.replace(~r/[^a-z0-9._\-+]/u, "")
  end

  @doc """
  Build a full address from a pattern, a name and a domain.
  """
  @spec build(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :missing_part | :unparseable}
  def build(pattern, full_name, domain) do
    with {:ok, parts} <- Names.split(full_name),
         {:ok, local} <- apply_pattern(pattern, parts) do
      {:ok, local <> "@" <> String.downcase(domain)}
    end
  end

  @doc """
  Work backwards: given an address and the name behind it, infer the pattern the
  company uses. This is how a `/pattern` lookup can answer from an address alone
  once we know whose address it is, and how a successful find teaches the cache
  a pattern we can reuse for free.
  """
  @spec derive(String.t(), String.t()) :: {:ok, String.t()} | {:error, :no_match}
  def derive(email, full_name) do
    with [local, _domain] <- String.split(email, "@", parts: 2),
         {:ok, parts} <- Names.split(full_name) do
      local = String.downcase(local)

      candidates()
      |> Enum.find_value({:error, :no_match}, fn pattern ->
        case apply_pattern(pattern, parts) do
          {:ok, ^local} -> {:ok, pattern}
          _ -> nil
        end
      end)
    else
      _ -> {:error, :no_match}
    end
  end

  @doc """
  Read a name back out of a local-part, given the company's pattern.

  `("john.smith", "{first}.{last}")` yields `%{first: "john", last: "smith"}`.

  Patterns with no separator between two full names (`{first}{last}`) are
  genuinely ambiguous — "johnsmith" could split a dozen ways — so those return
  `:error` rather than a confident guess at the wrong split.
  """
  @spec invert(String.t(), String.t()) :: {:ok, map()} | {:error, :ambiguous | :no_match}
  def invert(local, pattern) do
    tokens = Regex.scan(~r/\{([a-z]+)(?::(\d+))?\}/, pattern, capture: :all_but_first)
    full_tokens = Enum.count(tokens, fn [t | _] -> t in ~w(first last middle) end)
    separators = Regex.replace(~r/\{[a-z]+(?::\d+)?\}/, pattern, "")

    cond do
      full_tokens > 1 and separators == "" ->
        {:error, :ambiguous}

      true ->
        do_invert(local, pattern, tokens)
    end
  end

  defp do_invert(local, pattern, tokens) do
    regex_source =
      pattern
      |> String.split(~r/\{[a-z]+(?::\d+)?\}/, include_captures: true)
      |> Enum.map_join(fn part ->
        case Regex.run(~r/^\{([a-z]+)(?::(\d+))?\}$/, part, capture: :all_but_first) do
          [token] when token in ~w(first last middle) -> "([a-z0-9'\\-]+)"
          [token] when token in ~w(f l m) -> "([a-z0-9])"
          [_token, n] -> "([a-z0-9]{#{n}})"
          nil -> Regex.escape(part)
        end
      end)

    with {:ok, regex} <- Regex.compile("^" <> regex_source <> "$"),
         [_ | captures] <- Regex.run(regex, String.downcase(local)) do
      names =
        tokens
        |> Enum.map(fn [t | _] -> t end)
        |> Enum.zip(captures)
        |> Map.new(fn {token, value} -> {expand_token(token), value} end)

      {:ok, names}
    else
      _ -> {:error, :no_match}
    end
  end

  defp expand_token("first"), do: :first
  defp expand_token("last"), do: :last
  defp expand_token("middle"), do: :middle
  defp expand_token("f"), do: :first_initial
  defp expand_token("l"), do: :last_initial
  defp expand_token("m"), do: :middle_initial
  defp expand_token(other), do: String.to_atom(other)

  @doc """
  Every pattern we know how to recognise, ordered roughly by how common it is in
  the wild. Used for reverse derivation and as the guess-order when a domain has
  no published pattern.
  """
  @spec candidates() :: [String.t()]
  def candidates do
    [
      "{first}.{last}",
      "{f}{last}",
      "{first}",
      "{first}{last}",
      "{first}_{last}",
      "{first}-{last}",
      "{last}.{first}",
      "{last}{f}",
      "{last}",
      "{f}.{last}",
      "{first}{l}",
      "{f}{l}",
      "{first}.{m}.{last}",
      "{f}{m}{last}",
      "{last}{first}",
      "{last}_{first}",
      "{first:3}{last:3}"
    ]
  end
end
