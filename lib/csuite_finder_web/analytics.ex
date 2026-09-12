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

  @tracker_src "https://seriouslysimpleanalytics.com/wa.js"
  @default_site "acct_ssl8gfuynd"

  # Pages the browser tracker stays off, by their own `nav` value: `:account`
  # holds credentials, and `false` is the admin dashboard, whose traffic is ours
  # and would be counted as a customer's.
  @no_tracker [:account, false]

  @doc """
  The `<script>` tags for a page.

  Takes the page's `nav` — which every page already declares — because that is
  what says which page this is without threading a path through the layout.
  Google's tag is emitted wherever it is configured; the browser tracker is not,
  see `browser_tracker/1`.
  """
  @spec tag(atom() | nil) :: String.t()
  def tag(nav \\ nil) do
    google =
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

    google <> browser_tracker(nav)
  end

  @doc """
  SeriouslySimpleAnalytics' browser tracker.

  It captures pageviews, engaged time, scroll depth, clicks, outbound clicks,
  forms and page-to-page flow on its own, with no tagging.

  **Left off the account page deliberately.** That page shows a plaintext API
  key once and nowhere else, and carries the password fields for registering and
  signing in. A tracker that captures form interaction has no business on it —
  their own documentation concedes the point in passing, noting that the server
  "drops password-typed values on arrival", which is only worth saying about a
  thing that can receive them. Everywhere else is marketing copy and public
  prices, where there is nothing to leak.
  """
  @spec browser_tracker(atom() | nil) :: String.t()
  def browser_tracker(nav \\ nil) do
    cond do
      is_nil(site_id()) -> ""
      nav in @no_tracker -> ""
      true -> ~s(<script src="#{@tracker_src}" data-site="#{site_id()}" defer></script>\n)
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
      //
      // A mailto is reported as "mailto:" and nothing more. `pathname` on a
      // mailto URL is the address itself, so once the buy buttons became mailto
      // links every CTA click was posting an email address into the analytics
      // property — which is the exact thing the query-string rule below exists
      // to prevent. Ours rather than a visitor's, but it does not belong there
      // either, and the next such link might not be ours.
      function path(url) {
        if (!url) return "";
        try {
          var parsed = new URL(url, window.location.origin);
          return parsed.protocol === "http:" || parsed.protocol === "https:"
            ? parsed.pathname
            : parsed.protocol;
        }
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

  The visit's length is sent every second as `dwell_time`, aligned to the wall
  clock so every visitor's events land on the same boundaries and two sessions
  compare without allowing for when each began.

  Each event carries `seconds: 1` — an increment, not a running total. GA4
  aggregates a custom metric by sum or average and never by maximum, so a
  cumulative counter reads wrong in every default view: a thirty-second visit
  sends 1..30, which sums to 465 and averages to 15.5, and only the maximum is
  the real answer. As an increment the sum *is* the dwell in seconds, and so is
  the event count. `elapsed` carries the running total alongside it for anyone
  looking at one visit rather than an aggregate.

  It stops after 300 dwell events **per session**, counted in `sessionStorage`.

  GA4's cap is per session — it drops everything after the 500th event — and this
  counter was per page, so every navigation handed the visitor a fresh budget.
  Three pages at four minutes each is over seven hundred dwell events; GA4 keeps
  the first five hundred and discards the rest. The discarded ones are whatever
  arrived last, and a `cta_click` always arrives after the dwell ticks that
  preceded it, so clicks were what went missing. It presented as clicks no longer
  registering.

  300 leaves roughly 200 for page views, scroll depth, reading marks and every
  click across a whole visit. A `dwell_capped` event marks the stop, once per
  session rather than once per page — otherwise the marker joins the problem.

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
      // One event a second, on the second. The first tick waits for the next
      // whole second so every visitor's events land on the same boundaries, and
      // two sessions compare without allowing for when each happened to begin.
      //
      // The cost is real and is accepted deliberately: GA4 caps a session at
      // 500 events, so a visit past roughly eight minutes stops recording
      // anything further — cta_click included.
      var marks = [15, 30, 60, 120];
      var reached = 0;
      var seconds = 0;
      var timer = null;

      // The budget is per SESSION, not per page, because that is how GA4's cap
      // works — it drops everything after the 500th event in a session.
      //
      // This counter used to live in the page, so every navigation handed the
      // visitor a fresh 400. Three pages at four minutes each is over seven
      // hundred dwell events, GA4 keeps the first five hundred, and the events
      // that arrive late are exactly the ones worth having: a cta_click lands
      // after the dwell ticks that preceded it, so the clicks were what got
      // dropped. It looked like clicks had stopped registering; what had
      // happened is that the counter ate the session.
      //
      // 300 leaves roughly 200 for page views, scroll depth, reading marks and
      // every click across a whole visit.
      var BUDGET = 300;
      var KEY = "csf_dwell_sent";

      // sessionStorage throws outright in some privacy modes. Falling back to a
      // page-local count keeps today's behaviour rather than breaking the timer.
      var local = 0;

      function spent() {
        try {
          var raw = window.sessionStorage.getItem(KEY);
          return raw ? (parseInt(raw, 10) || 0) : 0;
        } catch (e) { return local; }
      }

      function spend(total) {
        local = total;
        try { window.sessionStorage.setItem(KEY, String(total)); } catch (e) {}
      }

      function stop() {
        if (timer) { window.clearInterval(timer); timer = null; }
      }

      function tick() {
        // Only while the tab is in front. GA4 counts engagement the same way,
        // and a tab left open overnight is not two hours of reading.
        if (document.visibilityState !== "visible") return;

        var used = spent();
        if (used >= BUDGET) {
          stop();

          // Once per session rather than once per page, or the marker itself
          // becomes the thing filling the budget.
          try {
            if (!window.sessionStorage.getItem(KEY + "_capped")) {
              window.sessionStorage.setItem(KEY + "_capped", "1");
              send("dwell_capped", { seconds: used, page_path: window.location.pathname });
            }
          } catch (e) {}

          return;
        }

        spend(used + 1);
        seconds += 1;

        // `seconds: 1` is the increment, not the running total, and that is
        // the whole point: GA4 aggregates a custom metric by sum or average,
        // never by max. A cumulative counter therefore reads wrong in every
        // default view — a thirty-second visit sends 1..30, which sums to 465
        // and averages to 15.5, and only the maximum is the real answer.
        //
        // Sent as an increment, all three readings agree: the sum is the dwell
        // in seconds, the event count is the dwell in seconds, and `elapsed`
        // still carries the running total for anyone who wants the shape of a
        // single visit.
        send("dwell_time", {
          seconds: 1,
          elapsed: seconds,
          page_path: window.location.pathname
        });

        while (reached < marks.length && seconds >= marks[reached]) {
          send("time_on_page", {
            seconds: marks[reached],
            page_path: window.location.pathname
          });
          reached += 1;
        }

      }

      window.setTimeout(function () {
        tick();
        timer = window.setInterval(tick, 1000);
      }, 1000 - (Date.now() % 1000));
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

  @doc """
  The SeriouslySimpleAnalytics site the browser tracker reports to, or nil.

  Configured the same way as the measurement id above: a default that works on
  deploy, overridable per environment, and blank to switch it off.
  """
  @spec site_id() :: String.t() | nil
  def site_id do
    case Application.get_env(:csuite_finder, :ssa_site_id, @default_site) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
