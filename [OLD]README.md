# CSuiteFinder

Resolve a name and a company domain to a work email — and answer the questions
that follow: is it deliverable, whose is it, what format does that company use,
and what is the company.

Elixir/Phoenix + PostgreSQL, with [treg](https://treg.to) as the data provider
and PayPal for top-ups.

## The idea

A raw email lookup costs $0.005–$0.02 **per person**. A company's email *pattern*
costs $0.0019 **once** and then resolves every employee of that company for
nothing.

So the finder tries, in order:

1. **Cache** — someone may already have asked. Free.
2. **Pattern** — one $0.0019 lookup, then free forever for that domain.
3. **A colleague's address**, if the caller supplies one — the pattern is worked
   backwards out of it rather than bought.
4. **A paid find**, capped at $0.02, only when there is no pattern to apply.

And every paid find teaches the pattern cache on the way out, so the expensive
path makes the cheap path better for the next caller. Measured on live calls:

| | first person at a company | second person |
|---|---|---|
| pattern path | $0.0019 | **$0.00** |
| raw find | $0.005 | $0.005 |

## Endpoints

All under `/csuitefinder`, all accepting `GET` (query string) or `POST` (JSON).
Authenticate with `Authorization: Bearer <api_key>` or `X-API-Key`.

| Endpoint | Params | Upstream budget |
|---|---|---|
| `POST /email/find` | `full_name`, `domain`, `email` *(optional)* | $0.02 |
| `POST /email/deliverable` | `email` | $0.002 |
| `POST /email/enrich` | `email` | $0.005 |
| `POST /email/pattern` | `email` | $0.01 |
| `POST /name/who` | `email` | $0.005 |
| `POST /company/find` | `email` | $0.005 |
| `POST /company/info` | `email` *(or `domain`)* | $0.005 |

`/company/find` and `/company/info` share one lookup and one cached row.
`find` answers "which company is this" — name, domain, website, LinkedIn —
while `info` returns the full profile. Same relationship as `/name/who` to
`/email/enrich`: the narrower endpoint exists so a caller who wants a name does
not have to read past a paragraph of marketing copy to find it.

The optional `email` on `/email/find` is a **known colleague's address at the
same company**: we identify whose it is, work the pattern backwards out of it,
and apply that pattern to the person you actually asked about. That is the
"find other emails" path, and it is cheaper than buying a find.

Budgets are enforced by treg itself via `X-Treg-Route-Max-Cost`, so a routing
change upstream can never spend more than the ceiling — an over-budget route
comes back as an unbilled miss.

### Supporting endpoints

| Endpoint | What it gives you |
|---|---|
| `GET /` | landing page with registration instructions |
| `POST /register` | create an account, get a key and the free trial |
| `GET /pricing` | token price, bundle minimum, per-endpoint rates |
| `GET /health` | liveness, DB, provider configuration |
| `GET /billing/balance` | token balance and price list |
| `GET /billing/usage?days=30` | per-endpoint calls, cache hits, tokens spent |
| `POST /billing/topup` | buy a token bundle ($1,000 min), returns the approval URL |
| `POST /billing/capture` | capture an approved order and credit the account |
| `POST /billing/webhook` | PayPal's callback (signature-verified) |
| `GET /ops/costs` | the cost model's current provider ranking |
| `GET /ops/cache` | cache row counts, hit rate, margin |
| `GET /admin` | admin dashboard (see below) |
| `GET /admin/metrics.json` | every dashboard figure as JSON |

### Example

```bash
curl -H "Authorization: Bearer $CSF_KEY" \
  "http://localhost:4000/csuitefinder/email/find?full_name=Jensen%20Huang&domain=nvidia.com"
```

```json
{
  "email": "jhuang@nvidia.com",
  "full_name": "Jensen Huang",
  "domain": "nvidia.com",
  "found": true,
  "confidence": 0.937638
}
```

## Everything is cached

| Table | Keyed on | Positive TTL | Negative TTL |
|---|---|---|---|
| `email_patterns` | domain | 180 d | 14 d |
| `emails` | name + domain | 90 d | 30 d |
| `email_verifications` | email | 30 d (90 d if dead) | 7 d |
| `person_enrichments` | email | 90 d | 30 d (inferred) |
| `company_profiles` | domain | 60 d | 60 d |

Negative results are cached too, on shorter TTLs — a domain nobody can pattern
today may well have one next month, but we should not pay to rediscover that on
every request.

**A known value is never discarded.** The TTL decides when we go and *look
again*, not whether we still hold the answer. If that refresh comes back empty —
the provider is down, or has since dropped the record — the previous value stays
put, `refresh_failures` is incremented, and the retry clock is pushed out a day.
The row is then served with `stale: true` and `last_verified_at`, so a caller can
judge for themselves whether an older answer is good enough. Replacing a correct
answer with the nothing we just got, and then caching that nothing, is the
failure this design exists to prevent.

An inferred guess never displaces a real record either: `known?` is tied to the
provider, not to whether the row has a name in it.

## Admin dashboard

`GET /admin` — headline counters, find economics, a 30-day volume chart,
per-endpoint traffic, customers and deferred revenue, cache size, and the
provider ranking. Auto-refreshes every 60 seconds; switch the window with the
7d/30d/90d links. `GET /admin/metrics.json` returns the same figures for
scripting or an external monitor.

```bash
export ADMIN_TOKEN="$(openssl rand -hex 32)"
open "http://localhost:4000/admin?token=$ADMIN_TOKEN"
```

The token may arrive as `Authorization: Bearer`, `X-Admin-Token`, or a `token`
query parameter (the last so the page opens from a browser address bar). It is
compared in constant time. **If `ADMIN_TOKEN` is unset the dashboard returns
503, not a page** — the failure mode of a missing environment variable should be
"nobody sees the metrics", never "everybody does".

### The number that matters

The dashboard is arranged around one question: **are finds profitable?** A find
sells for one token ($0.0025). A cached find costs us nothing, so it is nearly
pure margin. A fresh find falls through to a paid provider and can cost up to
$0.02 — more than it earns. The average of the two hides this, so the panel
splits them and computes the **break-even cache rate**: the share of finds that
must come from cache for the blend to net to zero.

    break_even = (avg_fresh_cost - token_price) / avg_fresh_cost

If the gauge's fill is past the mark, finds make money. If a fresh find already
costs less than it sells for — which is what happens while the pattern path
dominates at $0.0019 — break-even is 0% and every find is profitable regardless
of the mix.

Charts are server-rendered SVG: no external dependencies, works with JavaScript
disabled, and cannot break because a CDN moved.

## What the API discloses

Responses carry the customer's answer and nothing else. How a result was
derived, which upstream served it, what it cost us, and whether the cache
answered are all internal — they name our suppliers and price our margin, so
they stay on our side of the boundary.

`CsuiteFinderWeb.PublicView` is that boundary, and it works by **whitelist**:
a field added to a context stays internal unless it is listed there on purpose.
`test/csuite_finder_web/no_leak_test.exs` asserts, per endpoint, that no
response carries an internal key, that every key it does carry is in the view,
and — as a substring sweep over the encoded body — that no supplier is named
anywhere, including inside values we pass through.

The one deliberate exception is `/email/pattern`, which still returns
`pattern`: that is the answer the endpoint exists to give. What it no longer
returns is where the pattern came from.

`/csuitefinder/ops/*` ranks every upstream by name and price, so it sits behind
the admin token rather than any customer's API key. `/health` reports
`lookups_configured` rather than naming a vendor, and a failed lookup is logged
in full but answered with a generic message — an upstream's error body can carry
its name, its vocabulary and sometimes its quota.

None of this changes what is stored. Billing depends on knowing whether a result
was provider-verified or inferred, the cost model depends on knowing who served
it, and the admin dashboard shows all of it.

## The cost model

`/ops/costs` ranks providers by **expected cost per success**, not sticker price:

```
hit_rate = (weighted_hits + 1) / (weighted_attempts + 2)     # Beta(1,1) prior
score    = cost_per_hit / hit_rate                            # micro-USD per success
```

Two details do the real work:

**Difficulty weighting.** Providers in a waterfall do not see the same
questions — the fourth provider only ever sees what three others already failed.
Scoring them on raw hit rate punishes them for the position we put them in. So
each attempt records `prior_failures`, and a hit is weighted `1 + prior_failures`:
a hit after three misses is four times the evidence of a hit anyone could have
managed. treg reports its whole waterfall in `_treg.tried`, so one response tells
us how every provider did on the same question — including the misses.

**Zero-hit providers.** Per-success providers bill nothing on a miss, so a
provider that has missed twenty times has spent $0. Naive cost-per-hit
arithmetic reads that as *free* and ranks it first, ahead of everything that
works. A provider with no hits is instead priced at what a hit costs elsewhere in
that capability, which puts it last, where it belongs. (`cost_is_estimated: true`
marks these.)

## The inferred fallback

When no provider can identify an address, `/email/enrich` and `/name/who` still
answer, by reading the name out of the address — using the company's cached
pattern to invert it where we have one, so `john.smith@acme.com` is *known* to
split as John Smith rather than guessed at.

That answer is always labelled:

```json
{ "confidence": "low" }
```

It is stored in its own right so it can be told apart from provider data later,
it is **not billed**, and a shared mailbox (`info@`, `support@`) returns nobody
rather than inventing a person. An `flast` address yields the surname and admits
it does not know the first name, instead of reporting "Mbenioff" as a name.

The guess is offered — clearly marked — rather than disguised, because an
unmarked guess poisons the cache for every later caller and puts bounces in
someone's sending reputation.

## Pricing and billing

Tokens are the unit of account: **$0.0025 each**, sold in bundles from
**$1,000** (400,000 tokens). Every new account gets **400 free trial tokens
($1)** on registration — 400 real email lookups, enough to evaluate the API
without talking to anyone.

**You pay for emails found, and nothing else.**

| Endpoint | Tokens | Effective |
|---|---:|---:|
| `email.find` | 1 | $0.0025 |
| `email.deliverable` | — | included |
| `email.enrich` | — | included |
| `email.pattern` | — | included |
| `name.who` | — | included |
| `company.find` | — | included |
| `company.info` | — | included |

The find is the reason anyone is here; the follow-up questions are what make a
found address worth having, and metering them would only push callers to ask
fewer of them.

Included is not the same as ungated. Those endpoints still require a **positive
token balance** — they just don't spend it. Without that rule an account that had
spent to zero, or never bought anything, would keep unlimited access to five of
the six endpoints, and the enrichment calls behind them cost us real money per
request. A balance is what makes someone a customer; the token price is a
separate question. The refusal says which rule was missed (`reason:
"no_balance"` vs `"cannot_afford"`, plus `metered`), because the fix for the
first one is buying anything at all.

Pricing the product in tokens rather than dollars means a per-endpoint rate can
be tuned without repricing tokens a customer already holds.

Charges are per **answer**: a find that resolves nothing is free, an inferred
guess is free, and a cache hit costs the same as a fresh lookup (identical value
to the caller, and the margin on repeat questions is what pays for the lookups
that cost $0.02 and find nothing).

Balance is checked *before* the upstream call, so an empty account cannot spend
our money at a provider. Debits are conditional `UPDATE`s, so concurrent requests
on one key cannot both pass the check and overdraw.

The $1,000 bundle minimum is enforced server-side, before PayPal is involved, so
an under-minimum request never becomes a real order someone can approve. Captures
credit tokens derived from **what PayPal says was captured**, never what the
client claimed, and are keyed on the order id with a unique constraint so a
retried webhook cannot credit twice.

## Registering

```bash
curl -X POST http://localhost:4000/csuitefinder/register \
  -H 'content-type: application/json' \
  -d '{"email": "you@company.com"}'
```

Returns an API key and the trial tokens. The key is shown once and stored only
as a SHA-256 hash — it cannot be recovered afterwards. Send it as
`Authorization: Bearer <key>` on every request.

The landing page at `/` documents all of this for humans, rendered from the same
pricing constants the API bills on, so a price change moves the page and the
invoice together. `GET /csuitefinder/pricing` serves the same terms as JSON.

## Running it

```bash
mix deps.get
mix ecto.setup
export TREG_TOKEN=...            # from `treg login`; TREG_ORG if it is an identity token
export ADMIN_TOKEN=...           # enables /admin; without it the dashboard is closed
mix run priv/repo/seeds.exs      # registers a demo account, prints its API key
mix phx.server
```

PayPal is optional in development (`/health` reports `payments_configured`):

```bash
export PAYPAL_CLIENT_ID=... PAYPAL_CLIENT_SECRET=... PAYPAL_WEBHOOK_ID=...
export PAYPAL_MODE=live          # defaults to sandbox
```

## Deploying

See [DEPLOY.md](DEPLOY.md) — Ubuntu VPS, nginx, Let's Encrypt, systemd. Ready-made
files live in `deploy/`: a systemd unit, an nginx site, and an environment
template.

Short version: it is a Mix release behind nginx. **Not pm2** — that is a Node
process manager, and an OTP release already supervises itself; systemd gives you
boot ordering against Postgres, journald and sandboxing for free.

```bash
MIX_ENV=prod mix release --overwrite
_build/prod/rel/csuite_finder/bin/migrate
sudo systemctl restart csuite-finder
```

## Tests

```bash
mix test
```

145 tests, no network: treg is served by an in-process plug
(`CsuiteFinder.TregStub`), so the code under test is the code that runs in
production. Coverage includes name parsing (particles, accents, inversion,
mononyms), the pattern language in both directions, cache and billing
arithmetic, token pricing and the bundle minimum, the cost model's weighting and
ranking, registration and the trial grant, the balance gate on included
endpoints, dashboard metrics and their admin-token gate, and each endpoint's
caching behaviour
— including the assertion that a second colleague costs zero upstream calls, and
that a known value survives a refresh that comes back empty.
