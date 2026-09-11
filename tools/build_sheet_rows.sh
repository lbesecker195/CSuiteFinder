#!/usr/bin/env bash
# Build sample-sheet rows by calling CSuiteFinder's own API.
#
# The sheet claims every row is real output of this service. This is the script
# that keeps that true: it resolves each person through /email/find, checks the
# address through /email/deliverable, and masks it the way the sheet does — so
# the rows are literally the product working on itself.
#
#   CSF_KEY=csf_live_... tools/build_sheet_rows.sh [base_url] < people.tsv
#
# Input is one "Full Name<TAB>domain<TAB>Title" per line on stdin.
# Output is Elixir map literals ready to paste into CsuiteFinderWeb.SampleSheet.
set -euo pipefail

BASE="${1:-https://csuitefinder.com}"
: "${CSF_KEY:?set CSF_KEY to an API key with credit}"

api() { curl -s -H "Authorization: Bearer $CSF_KEY" "$BASE/csuitefinder/$1"; }

while IFS=$'\t' read -r name domain title; do
  [ -z "${name:-}" ] && continue

  found=$(api "email/find?full_name=$(printf %s "$name" | sed 's/ /%20/g')&domain=$domain")
  email=$(printf %s "$found" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("email") or "")')

  if [ -z "$email" ]; then
    printf '# no address found for %s at %s — row skipped\n' "$name" "$domain" >&2
    continue
  fi

  check=$(api "email/deliverable?email=$email")
  status=$(printf %s "$check" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status") or "unknown")')

  # "unknown" means the check could not run, not that the mailbox is dead.
  # Publishing it as either verdict would put a claim on the page that nobody
  # made, so the row is left out and said so.
  if [ "$status" = "unknown" ]; then
    printf '# %s <%s>: deliverability could not be checked — row skipped\n' "$name" "$email" >&2
    continue
  fi

  python3 - "$name" "$domain" "$title" "$email" "$status" <<'PY'
import sys
name, domain, title, email, status = sys.argv[1:6]

# The sheet's masking rule: keep the first two letters of every name-part and
# every separator, so a reader can see the company's format and still cannot
# write to anybody.
local, _, host = email.partition("@")
out, run = [], 0
for ch in local:
    if ch.isalnum():
        run += 1
        out.append(ch if run <= 2 else "•")
    else:
        run = 0
        out.append(ch)
masked = "".join(out) + "@" + host

# Only a confirmed mailbox is shown as deliverable. accept_all is shown that way
# too — mail to it is accepted and does not bounce, which is what the column
# means to someone about to send — and `raw` keeps what the check really said.
# Only two verdicts reach here; "unknown" was dropped upstream.
sheet = ":deliverable" if status in ("deliverable", "accept_all") else ":undeliverable"
raw = {"deliverable": ":confirmed", "accept_all": ":accept_all"}.get(status, ":rejected")

print(f'''    %{{
      name: "{name}",
      company: "{domain.split('.')[0].title()}",
      title: "{title}",
      email: "{masked}",
      status: {sheet},
      title_source: :public_record,
      raw: {raw}
    }},''')
PY
done
