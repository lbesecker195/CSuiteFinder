defmodule CsuiteFinder.Lookup do
  @moduledoc """
  How a single lookup was served: from cache, or by spending money.

  These two facts travel together everywhere, and they are not derivable from
  each other — a provider miss costs nothing but is emphatically not a cache
  hit, and reporting it as one would tell the caller their quota was untouched
  when we had in fact just used their upstream budget for the answer.
  """

  @type meta :: %{cached: boolean(), spent_micro: non_neg_integer()}

  @doc "Served from cache: nothing spent."
  @spec hit() :: meta()
  def hit, do: %{cached: true, spent_micro: 0}

  @doc "Served upstream, having spent `micro` micro-USD (possibly zero)."
  @spec miss(non_neg_integer()) :: meta()
  def miss(micro), do: %{cached: false, spent_micro: micro}

  @doc "Add upstream spend to an existing lookup, marking it non-cached."
  @spec add(meta(), non_neg_integer()) :: meta()
  def add(%{spent_micro: spent}, micro),
    do: %{cached: false, spent_micro: spent + micro}

  @doc "The `cost` block every endpoint returns."
  @spec cost_block(meta()) :: map()
  def cost_block(%{spent_micro: micro}) do
    %{provider_micro: micro, provider_usd: Float.round(micro / 1_000_000, 6)}
  end
end
