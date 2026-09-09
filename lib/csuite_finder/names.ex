defmodule CsuiteFinder.Names do
  @moduledoc """
  Normalising human names into the parts an email pattern needs.

  Everything here is deterministic and free — it runs before we spend anything
  with a provider, and it produces the cache key that lets a second user asking
  the same question pay nothing at all.
  """

  # Particles that belong to the surname rather than being a middle name, so
  # "Ludwig van Beethoven" keeps "van beethoven" together instead of splitting
  # on the wrong token.
  @particles ~w(van von de del della der den des di da dos du la le las los mac mc bin ibn al st saint ter ten)

  @suffixes ~w(jr sr ii iii iv v phd md dds esq mba cpa)

  @titles ~w(mr mrs ms miss dr prof sir madam mx rev capt lt sgt)

  @doc """
  Split a full name into `{first, middle, last}`.

  Handles "Last, First" ordering, strips titles and suffixes, and keeps surname
  particles attached to the surname.
  """
  @spec split(String.t()) :: {:ok, map()} | {:error, :unparseable}
  def split(full_name) when is_binary(full_name) do
    tokens =
      full_name
      |> handle_comma_order()
      |> String.split(~r/[\s]+/, trim: true)
      |> Enum.map(&clean_token/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&(&1 in @titles))
      |> Enum.reject(&(&1 in @suffixes))

    case tokens do
      [] ->
        {:error, :unparseable}

      [only] ->
        # A mononym still resolves patterns that only need a first name.
        {:ok, %{first: only, middle: nil, last: nil, tokens: tokens}}

      _ ->
        {first, rest} = {hd(tokens), tl(tokens)}
        {middle, last} = take_surname(rest)
        {:ok, %{first: first, middle: middle, last: last, tokens: tokens}}
    end
  end

  def split(_), do: {:error, :unparseable}

  # "Collison, Patrick" -> "Patrick Collison"
  defp handle_comma_order(name) do
    case String.split(name, ",", parts: 2) do
      [last, first] ->
        # A trailing suffix ("John Smith, Jr") is not a surname inversion.
        if strip_punct(String.downcase(String.trim(first))) in @suffixes do
          last
        else
          String.trim(first) <> " " <> String.trim(last)
        end

      [single] ->
        single
    end
  end

  defp clean_token(token) do
    token
    |> String.downcase()
    |> deaccent()
    |> strip_punct()
  end

  defp strip_punct(s), do: String.replace(s, ~r/[^a-z0-9'\-]/u, "")

  @doc """
  Fold accented characters down to ASCII, because mailbox local-parts are ASCII.

  Only the combining marks are removed — separators such as `.` survive, since
  this also runs over assembled local-parts where the punctuation is the pattern.
  """
  @spec deaccent(String.t()) :: String.t()
  def deaccent(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.downcase()
  end

  # Walk from the end back over particles so "de la cruz" stays whole.
  defp take_surname(rest) do
    idx =
      rest
      |> Enum.with_index()
      |> Enum.reduce(length(rest) - 1, fn {tok, i}, acc ->
        if tok in @particles and i < acc, do: min(acc, i), else: acc
      end)

    {middle_toks, last_toks} = Enum.split(rest, idx)

    middle = if middle_toks == [], do: nil, else: Enum.join(middle_toks, " ")
    last = if last_toks == [], do: nil, else: Enum.join(last_toks, "")

    {middle, last}
  end

  @doc """
  Stable cache key for a person, so "Patrick Collison", "patrick  collison" and
  "Collison, Patrick" all hit the same cached row.
  """
  @spec name_key(String.t()) :: String.t()
  def name_key(full_name) do
    case split(full_name) do
      {:ok, %{tokens: tokens}} -> Enum.join(tokens, " ")
      {:error, _} -> full_name |> String.downcase() |> String.trim()
    end
  end
end
