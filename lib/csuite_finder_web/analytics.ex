defmodule CsuiteFinderWeb.Analytics do
  @moduledoc """
  The Google Analytics tag, rendered into every HTML page.

  Defined once rather than pasted into each template: these pages share no
  layout, so five copies would drift the first time the property changed, and a
  page silently missing the tag is invisible in the numbers rather than
  obviously broken.

  The measurement id is configurable so a staging deployment does not report
  into production's property. Unset means no tag is emitted at all — which is
  what you want in tests and in dev, where the traffic is yours and would only
  pollute the data.
  """

  @default_id "G-632F1T5SQ2"

  @doc "The `<script>` tags, or an empty string when analytics are switched off."
  @spec tag() :: String.t()
  def tag do
    case measurement_id() do
      nil ->
        ""

      id ->
        """
        <!-- Google tag (gtag.js) -->
        <script async src="https://www.googletagmanager.com/gtag/js?id=#{id}"></script>
        <script>
          window.dataLayer = window.dataLayer || [];
          function gtag(){dataLayer.push(arguments);}
          gtag('js', new Date());

          gtag('config', '#{id}');
        </script>
        #{click_tracking()}
        """
    end
  end

  @doc """
  Report every link and button click as a `cta_click` event.

  One delegated listener rather than a handler per element, so a button added
  later is tracked without anybody remembering to wire it up — which is the
  failure mode that makes click data untrustworthy: the numbers look complete
  and are quietly missing whichever control was added last.

  **No query strings are ever sent.** A campaign link arrives as
  `?email=someone@company.com`, and both the page's own URL and a relative href
  can carry it. Paths only, here and for the page location, so an address the
  visitor never typed cannot end up in an analytics property.
  """
  @spec click_tracking() :: String.t()
  def click_tracking do
    """
    <script>
    (function () {
      "use strict";

      // Strip the query and fragment. Absolute or relative, same rule.
      function path(url) {
        if (!url) return "";
        try { return new URL(url, window.location.origin).pathname; }
        catch (e) { return ""; }
      }

      function text(el) {
        return (el.textContent || "").replace(/\s+/g, " ").trim().slice(0, 80);
      }

      document.addEventListener("click", function (event) {
        var el = event.target.closest && event.target.closest("a, button");
        if (!el || typeof window.gtag !== "function") return;

        var href = el.getAttribute("href") || "";

        // What was being bought, said by the markup rather than guessed from
        // the URL. The two offers are $999 and $29.99 and they convert at very
        // different rates, so "somebody clicked a checkout link" is not an
        // answer worth having. `data-cta` survives a change of processor or of
        // route; a path does not, and this site has changed both twice.
        var offer = el.closest("[data-cta]");
        var external = /^https?:/i.test(href) &&
                       href.indexOf(window.location.origin) !== 0;

        var event = {
          element: el.tagName.toLowerCase(),
          link_text: text(el),
          link_id: el.id || "",
          link_classes: (el.className || "").toString().slice(0, 60),
          link_path: external ? href.split("?")[0] : path(href),
          outbound: external,
          page_path: window.location.pathname
        };

        if (offer) {
          event.cta = offer.getAttribute("data-cta");

          // GA4 treats `value` as money when `currency` is alongside it, which
          // turns a click count into a pipeline figure without any reporting
          // work.
          var usd = parseFloat(offer.getAttribute("data-cta-usd"));
          if (!isNaN(usd)) {
            event.value = usd;
            event.currency = "USD";
          }
        }

        window.gtag("event", "cta_click", event);
      }, true);
    })();
    </script>
    """
  end

  @doc "The configured measurement id, or nil when analytics are off."
  @spec measurement_id() :: String.t() | nil
  def measurement_id do
    case Application.get_env(:csuite_finder, :ga_measurement_id, @default_id) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
