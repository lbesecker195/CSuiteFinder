<h1 align="center">CSuiteFinder</h1>

<p align="center">
  <strong>Get the CEO's work email. Then the rest of the C-suite.</strong><br>
  One line to your AI assistant. A verified CSV back.
</p>

<p align="center">
  <a href="https://csuitefinder.com/start"><strong>Start here →</strong></a> ·
  <a href="https://csuitefinder.com/teams">For sales teams</a> ·
  <a href="https://csuitefinder.com/developers">For developers</a> ·
  <a href="https://csuitefinder.com/llms.txt">llms.txt</a>
</p>

---

## Paste this into Claude, ChatGPT, Cursor or Copilot

```
Read https://csuitefinder.com/llms.txt and use the CSuiteFinder API and store my token `csf_live_...` to be used. Then run /demo
```

That is the whole integration. Your assistant reads one URL and learns every
endpoint, every parameter and every price, then goes to work.

No SDK to install. No client library to pin. No documentation to read. No ticket
for an engineer.

**[Get your token and paste the line →](https://csuitefinder.com/start)**

---

## What comes back

Real output from this service, run on 9 September 2026. A name and a company
domain in — a work address and a job title out, every one checked against the
live mailbox before you see it:

| Name | Company | Title | Email | Deliverable |
|---|---|---|---|---|
| Michael Miebach | Mastercard | CEO | `mi•••••_mi•••••@mastercard.com` | ✅ |
| Sasan Goodarzi | Intuit | CEO | `sa•••_go••••••@intuit.com` | ✅ |
| Chris Suh | Visa | EVP, CFO | `cs••@visa.com` | ✅ |
| Alex Chriss | PayPal | CEO | `ac•••••@paypal.com` | ✅ |
| Richard Fairbank | Capital One | CEO | `ri•••••.fa••••••@capitalone.com` | ✅ |
| Stephen Squeri | American Express | CEO | `st•••••.sq••••@americanexpress.com` | ❌ |

No two of these companies build addresses the same way — Visa uses `flast`,
Mastercard `first_last`, Amex `first.last` — and none of them publish the rule.
That is the part you cannot guess.

Addresses are masked here because these are real people. **The two marked ❌ are
left in on purpose:** that is the deliverability check doing its job in public.
A tool that never shows you a failure is a tool that is hiding them.

Prospects.csv, ready for your CRM.

**[See it run →](https://csuitefinder.com/start)**

---

## Ten commands your assistant already understands

| | |
|---|---|
| `/demo` | Twenty checked C-suite rows from any company |
| `/find` | A name and a company → their work email |
| `/room` | Everyone worth knowing at one domain |
| `/list` | Build a prospect list from who you sell to |
| `/reach` | The list, with every address verified |
| `/titles` | Who holds a given role, by company or country |
| `/clean` | Scrub an existing list of dead addresses |
| `/whois` | An email, phone or domain → the person behind it |
| `/whocalled` | Identify an unknown number |
| `/spend` | What you have used, and what is left |

You type the command. Your assistant makes the calls, checks the addresses, and
hands you the file.

**[Read the full command list →](https://csuitefinder.com/llms.txt)**

---

## Pricing

| | |
|---|---|
| **Trial** | **$29.99 once** — $29.99 of real credit, one month. Not a limited preview. |
| **Seat** | **$999/month** — about 399,600 work emails a month. |
| **Annual** | **$9,990/year** — twelve months for the price of ten. |

Per answer, it is **$0.0025 an email address**. Deliverability checks, company
lookups, email formats and identity lookups are **included**. A lookup that
finds nothing is **free**. Credit you buy **never expires**.

**[Start the $29.99 trial →](https://csuitefinder.com/checkout)** ·
**[Take a seat →](https://csuitefinder.com/teams)**

---

## Would rather call it yourself?

It is a plain JSON API over HTTPS. One bearer token, no client library.

```bash
curl -H "Authorization: Bearer $CSF_KEY" \
  "https://csuitefinder.com/csuitefinder/email/find?full_name=Jensen%20Huang&domain=nvidia.com"
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

| You have | Endpoint | Price |
|---|---|---|
| A name and a company | `/email/find` | $0.0025 |
| Only the company | `/email/company/people` | $0.0025 a person |
| An address to check | `/email/deliverable` | included |
| An address, want the person | `/email/enrich`, `/name/who` | included |
| A domain, want the format | `/email/pattern` | included |
| A domain, want the company | `/company/find`, `/company/info` | included |

Every price is served live at
[`/csuitefinder/pricing`](https://csuitefinder.com/csuitefinder/pricing) — no key
needed — so what you are quoted is what you are charged.

**[Full endpoint reference →](https://csuitefinder.com/developers)**

---

## Why the addresses hold up

**Every address is checked against the live mailbox** before it reaches you, and
the verdict travels with the row. `accept_all` is reported as `accept_all`, not
quietly upgraded to a pass — a domain that accepts everything has told you
nothing, and pretending otherwise is how a list bounces.

**A known answer is never thrown away.** When a refresh comes back empty because
a provider is down, the previous answer stays and the row is served with
`stale: true` and the date it was last confirmed, so you can judge it yourself.
Replacing a correct answer with nothing is the failure this is built to avoid.

**Fewer than twenty is a real answer.** A short sheet means a small executive
team, not a broken search. Nothing widens the query to pad a row count.

---

## Questions people actually ask

**Do I need to write any code?** No. If you use an AI assistant, paste the line
above and you are done. If you would rather call the API, it is one `curl`.

**Is there a free tier?** No. The trial is $29.99 and buys $29.99 of real
credit — real lookups against live data, not a sandbox.

**What if it finds nothing?** You are not charged. Misses are free.

**Can my team share one account?** Yes. A seat's credit is pooled, and a key is
a key — pass it around.

**How fresh is it?** Addresses are resolved from live sources and re-checked on
a schedule, and any row served from an older answer is labelled `stale` with the
date it was last confirmed — so you are never guessing how old a result is.

---

<p align="center">
  <strong><a href="https://csuitefinder.com/start">Get your token and run /demo →</a></strong><br>
  <sub><a href="https://csuitefinder.com/">csuitefinder.com</a> ·
  <a href="https://csuitefinder.com/teams">Sales teams</a> ·
  <a href="https://csuitefinder.com/developers">Developers</a> ·
  <a href="https://csuitefinder.com/account">Your account</a></sub>
</p>

<p align="center"><sub>© Logan Besecker 2026</sub></p>
