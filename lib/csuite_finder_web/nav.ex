defmodule CsuiteFinderWeb.Nav do
  @moduledoc """
  The site header, defined once and rendered into each page.

  These pages are separate EEx templates with no layout between them, so without
  this the nav would exist in three places and drift the first time a link
  changed. `current` marks the active item.
  """

  @links [
    {:teams, "/teams", "For sales teams"},
    {:developers, "/developers", "For developers"},
    {:pricing, "/#pricing", "Pricing"}
  ]

  # The key the account page stores in the visitor's browser. Its presence is
  # what decides whether the last nav item reads "Register / Log in" or
  # "Dashboard".
  @key_store "csf_api_key"

  @doc """
  The header markup. `current` is the key of the page being rendered, or `nil`.

  Returns a raw string: these templates are plain EEx with no HTML escaping, and
  everything here is a literal — no caller input reaches it.
  """
  @spec render(atom()) :: String.t()
  def render(current \\ nil) do
    items =
      Enum.map_join(@links, "\n", fn {key, href, label} ->
        active = if key == current, do: ~s( class="on"), else: ""
        ~s(      <a href="#{href}"#{active}>#{label}</a>)
      end)

    """
    <nav class="sitenav">
      <a class="brand" href="/">CSuiteFinder</a>
      <div class="navlinks">
    #{items}
        <a class="navcta" href="/account" id="nav-account">Register / Log in</a>
      </div>
    </nav>
    <script>
    // Someone who already has a key is not registering again — they want their
    // dashboard. The key lives only in this browser, so the swap has to happen
    // here rather than server-side. Rendered signed-out first, so a browser
    // that blocks storage still shows a sensible label instead of nothing.
    (function () {
      try {
        if (localStorage.getItem("#{@key_store}")) {
          document.getElementById("nav-account").textContent = "Dashboard";
        }
      } catch (e) {}
    })();
    </script>
    """
  end

  @doc "Styles for the header, injected into each page's stylesheet."
  @spec css() :: String.t()
  def css do
    """
      .sitenav{display:flex;align-items:center;justify-content:space-between;gap:18px;
        flex-wrap:wrap;padding:18px 0 0;margin-bottom:8px}
      .sitenav .brand{font-weight:700;font-size:15px;text-transform:uppercase;
        letter-spacing:.04em;color:var(--accent);text-decoration:none}
      .navlinks{display:flex;align-items:center;gap:20px;flex-wrap:wrap}
      .navlinks a{color:var(--muted);text-decoration:none;font-size:14.5px;font-weight:500}
      .navlinks a:hover{color:var(--accent)}
      .navlinks a.on{color:var(--text);font-weight:600}
      .navcta{background:var(--accent);color:#fff !important;padding:8px 15px;
        border-radius:8px;font-weight:600 !important;font-size:14px !important}
      .navcta:hover{filter:brightness(1.07)}
      @media (max-width:560px){
        .navlinks{gap:14px;font-size:14px}
        .sitenav{padding-bottom:6px}
      }
    """
  end
end
