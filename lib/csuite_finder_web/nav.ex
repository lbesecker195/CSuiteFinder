defmodule CsuiteFinderWeb.Nav do
  @moduledoc """
  The site header, defined once and rendered into each page.

  These pages are separate EEx templates with no layout between them, so without
  this the nav would exist in five places and drift the first time a link
  changed.

  ## The nav is audience-aware

  A salesperson and a developer are sold different things at different prices
  (see `CsuiteFinder.Audience`), and a header offering both is how a salesperson
  ends up reading a per-answer price list. So every item is tagged with the
  audience it belongs to and the rest are removed in the browser.

  Where the audience is known from the page itself — `/teams` is sales,
  `/developers` is not — the server says so and the page also *remembers* it, so
  the pages that cannot know (the account page, the fork) follow the visitor
  rather than guessing. When nothing is remembered the visitor is treated as
  sales, which is the price that is safe to show anybody.

  `Pricing` is deliberately a bare `#pricing` fragment: every page carries its
  own pricing section at the foot, so the link scrolls down the page the visitor
  is already on instead of sending them to the other audience's page.
  """

  alias CsuiteFinder.Audience

  # {key, href, label, audience} — audience `:any` shows to everyone.
  @links [
    {:teams, "/teams", "Seats", :sales},
    {:developers, "/developers", "The API", :developer},
    {:start, "/start", "Get started", :developer},
    {:pricing, "#pricing", "Pricing", :any}
  ]

  # What the account page stores in the visitor's browser. The key decides
  # whether the last nav item reads "Register / Log in" or "Dashboard"; the
  # audience decides which of the other items survive.
  @key_store "csf_api_key"
  @audience_store "csf_audience"
  # A campaign link can carry ?email=, so the signup field arrives filled in.
  # Captured here rather than on the account page because the visitor may land
  # anywhere — the link in an email points at whichever page makes the case.
  @email_store "csf_email"

  @doc """
  The header markup.

  `current` is the key of the page being rendered, or `nil`. `audience` is
  `:sales` or `:developer` when the page itself settles the question, and `nil`
  when it does not — in which case the browser's remembered audience decides,
  defaulting to sales.

  Returns a raw string: these templates are plain EEx with no HTML escaping, and
  everything here is a literal — no caller input reaches it.
  """
  @spec render(atom(), :sales | :developer | nil) :: String.t()
  def render(current \\ nil, audience \\ nil) do
    items =
      Enum.map_join(@links, "\n", fn {key, href, label, for_audience} ->
        active = if key == current, do: ~s( class="on"), else: ""
        ~s(      <a href="#{href}" data-aud="#{for_audience}"#{active}>#{label}</a>)
      end)

    """
    <nav class="sitenav">
      <a class="brand" href="#{home_for(audience)}">C Suite Finder.com</a>
      <div class="navlinks">
    #{items}
        <a class="navcta" href="/account" id="nav-account">Register / Log in</a>
      </div>
    </nav>
    #{script(audience)}
    """
  end

  defp home_for(:developer), do: "/developers"
  defp home_for(:sales), do: "/teams"
  defp home_for(_), do: "/"

  # Rendered as the sales nav and narrowed in the browser, so a visitor with
  # scripting off or storage blocked still gets a working header showing the
  # prices that are safe to show anybody.
  defp script(audience) do
    fixed = if audience in [:sales, :developer], do: ~s("#{audience}"), else: "null"

    """
    <script>
    (function () {
      var FIXED = #{fixed};
      var DEFAULT = "#{Audience.default()}";
      var audience = FIXED;

      try {
        // A page that knows its own audience is also the moment to record it:
        // arriving on /developers is what makes you a developer everywhere else.
        if (FIXED) localStorage.setItem("#{@audience_store}", FIXED);
        else audience = localStorage.getItem("#{@audience_store}");
        if (localStorage.getItem("#{@key_store}")) {
          document.getElementById("nav-account").textContent = "Dashboard";
        }
      } catch (e) {}

      // Take the address out of the URL once it is kept: an email in a query
      // string ends up in bookmarks, in referrer headers and on the screen of
      // whoever is looking over their shoulder. Only that parameter is removed,
      // because others on this page are load-bearing.
      try {
        var params = new URLSearchParams(window.location.search);
        var prefill = params.get("email");
        if (prefill) {
          localStorage.setItem("#{@email_store}", prefill.slice(0, 254));
          params.delete("email");
          var rest = params.toString();
          window.history.replaceState({}, "",
            window.location.pathname + (rest ? "?" + rest : "") + window.location.hash);
        }
      } catch (e) {}

      window.csfPrefillEmail = function () {
        try { return localStorage.getItem("#{@email_store}") || ""; }
        catch (e) { return ""; }
      };

      window.csfAudience = function () {
        if (FIXED) return FIXED;
        try { return localStorage.getItem("#{@audience_store}") || DEFAULT; }
        catch (e) { return DEFAULT; }
      };

      window.csfSetAudience = function (value) {
        if (value !== "sales" && value !== "developer") return;
        try { localStorage.setItem("#{@audience_store}", value); } catch (e) {}
        window.csfApplyAudience(value);
      };

      window.csfApplyAudience = function (value) {
        var a = value || DEFAULT;
        document.querySelectorAll("[data-aud]").forEach(function (el) {
          var want = el.getAttribute("data-aud");
          el.hidden = (want !== "any" && want !== a);
        });
      };

      window.csfApplyAudience(audience || DEFAULT);

      // The nav is parsed before the rest of the page, so the first pass only
      // reaches the header. Everything else — a pricing block, a purchase path,
      // a table column — is tagged the same way and narrowed once it exists.
      document.addEventListener("DOMContentLoaded", function () {
        window.csfApplyAudience(window.csfAudience());
      });
    })();
    </script>
    """
  end

  @doc "The browser key the visitor's audience is remembered under."
  @spec audience_store() :: String.t()
  def audience_store, do: @audience_store

  @doc "The browser key a campaign-supplied email is remembered under."
  @spec email_store() :: String.t()
  def email_store, do: @email_store

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
