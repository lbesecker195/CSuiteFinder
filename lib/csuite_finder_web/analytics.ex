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
        #{engagement_tracking()}
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

  @doc """
  Report reading milestones, so engagement time means something.

  GA4 does not have a stopwatch. It accumulates engagement time and sends it
  **attached to events**, so a visit with a page_view and nothing else gives it
  almost nothing to attribute: the reported average then reflects how often
  people happen to fire an event, not how long they stayed. A page with two
  events — arrive, click — tells GA4 about the visitors who clicked, and the
  ones who read carefully and left are counted as a few seconds.

  So this fires a handful of one-shot events: scroll depth at a quarter, a half,
  three quarters and the end, and elapsed time at 15, 30, 60 and 120 seconds.
  They exist to give GA4 timestamps to reason about, which is why each fires
  once and no more.

  The visit's actual length is counted every second and reported once, as
  `dwell_time`, when the visitor leaves. Those are deliberately two different
  things: a one-second tick is what makes the figure accurate to a second, while
  an event per second would be 120 events from a two-minute read to say
  something that can be said once at the end. It goes out over `beacon`, because
  an ordinary request is cancelled when the page goes away — which is exactly
  when it fires, and the visits worth measuring are the ones that end without a
  click.

  Time is only counted while the tab is actually visible, which is GA4's own
  definition of engagement. A page left open in a background tab overnight is
  not two hours of reading.
  """
  @spec engagement_tracking() :: String.t()
  def engagement_tracking do
    """
    <script>
    (function () {
      "use strict";

      if (typeof window.gtag !== "function" && !window.dataLayer) return;

      function send(name, params) {
        if (typeof window.gtag === "function") window.gtag("event", name, params);
      }

      // ---- how far down they read -----------------------------------------
      var depths = [25, 50, 75, 90];
      var seenDepth = {};

      function depth() {
        var doc = document.documentElement;
        var scrollable = doc.scrollHeight - window.innerHeight;
        // A page shorter than the window is fully read the moment it loads;
        // reporting 0% for it would drag every average down.
        var pct = scrollable <= 0 ? 100 : ((window.scrollY / scrollable) * 100);

        for (var i = 0; i < depths.length; i++) {
          var mark = depths[i];
          if (pct >= mark && !seenDepth[mark]) {
            seenDepth[mark] = true;
            send("scroll_depth", { percent: mark, page_path: window.location.pathname });
          }
        }
      }

      window.addEventListener("scroll", depth, { passive: true });
      depth();

      // ---- how long they stayed -------------------------------------------
      //
      // Counted every second, reported twice. The counter and the events are
      // deliberately different things: a tick per second is what makes the
      // final figure accurate to a second, while sending an event per second
      // would be 120 events from a two-minute read, for a number that can be
      // stated once at the end.
      var marks = [15, 30, 60, 120];
      var reached = 0;
      var seconds = 0;
      var reported = -1;

      window.setInterval(function () {
        // Only while the tab is in front. GA4 counts engagement the same way,
        // and a tab left open overnight is not two hours of reading.
        if (document.visibilityState !== "visible") return;

        seconds += 1;

        while (reached < marks.length && seconds >= marks[reached]) {
          send("time_on_page", {
            seconds: marks[reached],
            page_path: window.location.pathname
          });
          reached += 1;
        }
      }, 1000);

      // The exact figure, sent when they actually leave. `beacon` because a
      // normal request is cancelled when the page goes away, which is precisely
      // when this fires — and the whole point is to measure the visits that end
      // without a click.
      function report() {
        if (seconds === reported) return;
        reported = seconds;

        send("dwell_time", {
          seconds: seconds,
          page_path: window.location.pathname,
          transport_type: "beacon"
        });
      }

      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "hidden") report();
      });

      // pagehide as well as visibilitychange: a tab switch fires the first, a
      // navigation away fires both on some browsers and only this on others.
      // `report` is guarded against sending the same number twice, so the
      // overlap costs nothing.
      window.addEventListener("pagehide", report);
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
