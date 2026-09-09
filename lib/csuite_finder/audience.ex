defmodule CsuiteFinder.Audience do
  @moduledoc """
  Who an account is: a salesperson, or a developer.

  The two buy the same data on completely different terms — a seat at $999 a
  month, or credit priced per answer — and showing someone both at once sells
  them neither. A salesperson who sees a fraction of a cent next to $999 does
  the arithmetic and stops reading; a developer shown only a seat price
  concludes there is no API. So the audience is recorded on the account and
  decides what the whole site puts in front of them: which prices, which
  purchase path, which nav, which page the pricing link scrolls to.

  **An unknown audience is treated as sales.** That is the deliberate default:
  the seat price is the one that is safe to show to anybody, and a developer who
  sees it will go looking for the API anyway — the reverse is not true.
  """

  @audiences ~w(sales developer)
  @default "sales"

  @type t :: String.t()

  @doc "Every audience, as stored."
  @spec all() :: [t()]
  def all, do: @audiences

  @doc "The audience to assume when nothing says otherwise."
  @spec default() :: t()
  def default, do: @default

  @doc """
  Normalise anything — a param, an atom, `nil` — to a known audience.

  Never fails and never returns an unknown value: this is called on
  browser-supplied input, and the answer decides what a page renders.
  """
  @spec cast(term()) :: t()
  def cast(value) when value in @audiences, do: value
  def cast(value) when is_atom(value) and not is_nil(value), do: cast(Atom.to_string(value))

  def cast(value) when is_binary(value) do
    normalised = value |> String.trim() |> String.downcase()
    if normalised in @audiences, do: normalised, else: @default
  end

  def cast(_), do: @default

  @doc "The audience as an atom, for pattern matching in views."
  @spec key(term()) :: :sales | :developer
  def key(value), do: value |> cast() |> String.to_existing_atom()

  @spec sales?(term()) :: boolean()
  def sales?(value), do: cast(value) == "sales"

  @spec developer?(term()) :: boolean()
  def developer?(value), do: cast(value) == "developer"

  @doc "The landing page this audience belongs on."
  @spec home(term()) :: String.t()
  def home(value), do: if(developer?(value), do: "/developers", else: "/teams")

  @doc "How to describe the audience to itself."
  @spec label(term()) :: String.t()
  def label(value), do: if(developer?(value), do: "Developer", else: "Sales")
end
