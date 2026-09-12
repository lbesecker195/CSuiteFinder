#!/usr/bin/env bash
#
# Pull main, build it, and restart the service — but only when there is
# something new and only when it compiles.
#
# Run it by hand any time:
#
#     sudo bash /var/www/HoneyTrap/CSuiteFInder/deploy/autodeploy.sh
#
# or leave the timer to call it every ten minutes. Both paths run this same
# script, so "deploy now" and "deploy on the timer" cannot drift apart.
#
# Three things it refuses to do, each of which has cost somebody an afternoon:
#
#   * Rebuild when nothing has changed. A release build on this box takes
#     minutes and restarts the service. Ten-minute rebuilds of an unchanged tree
#     would mean the site restarts 144 times a day for no reason.
#   * Deploy a tree that does not compile. Warnings are errors here, which is
#     the gate that catches the mistake actually made in this repo before now: a
#     stray unused alias, pushed green locally because the warning scrolled past.
#   * Run twice at once. A build started while another is half-written produces
#     a release nobody can reason about.
#
# What it does NOT do is run the test suite. That belongs before the push —
# `mix precommit` — not on a 950MB box where it needs its own database. Set
# AUTODEPLOY_TEST=1 if you want it here as well and have created the test DB.

set -euo pipefail

APP_DIR="${APP_DIR:-/var/www/HoneyTrap/CSuiteFInder}"
ENV_FILE="${ENV_FILE:-/etc/csuite-finder.env}"
SERVICE="${SERVICE:-csuite-finder}"
BRANCH="${BRANCH:-main}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:4000/csuitefinder/health}"
LOCK="${LOCK:-/var/lock/csuite-finder-autodeploy.lock}"

# `date -Is` is GNU-only, and this script is worth being able to run on a Mac to
# check it does the right thing before it runs anywhere that matters.
log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "FAILED: $*"; exit 1; }

# One at a time. Without this the timer can start a build on top of a build.
#
# The missing-flock case is checked separately and loudly. `! flock -n 9` is
# also true when there is no flock at all, so without this the script would
# announce that another deploy is running, exit 0, and go on never deploying
# anything — a silent permanent no-op, which is the worst thing this could do.
command -v flock >/dev/null || die "flock is not installed (apt install util-linux)"

exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy is running; leaving it alone"
  exit 0
fi

cd "$APP_DIR" || die "no such directory: $APP_DIR"

git fetch --quiet origin "$BRANCH" || die "could not reach the remote"

local_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse "origin/$BRANCH")"

if [ "$local_sha" = "$remote_sha" ]; then
  log "already at ${local_sha:0:8}; nothing to do"
  exit 0
fi

log "deploying ${local_sha:0:8} -> ${remote_sha:0:8}"
git log --oneline "$local_sha..$remote_sha" | sed 's/^/    /'

# Anything uncommitted here is a hand-edit on the server. Refuse rather than
# silently throw it away: someone put it there for a reason and a pull that
# discards it is the kind of thing nobody finds out about until much later.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree is dirty — commit, stash or discard it, then run again"
fi

git merge --ff-only "origin/$BRANCH" || die "cannot fast-forward; the server has diverged"

# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a
export MIX_ENV=prod

# PHX_SERVER lives in that file because the same file configures the service.
# Inherited by a one-off mix task it starts a second web server, which cannot
# bind the port the running one holds.
unset PHX_SERVER

mix deps.get --only prod >/dev/null || die "deps.get"

# The gate. Warnings are errors, so this is what stops a red build reaching the
# site — it is cheap, and it catches the failure this repo has actually had.
log "compiling"
mix compile --warnings-as-errors || die "it does not compile; the running site is untouched"

if [ "${AUTODEPLOY_TEST:-0}" = "1" ]; then
  log "running the test suite"
  env MIX_ENV=test mix test || die "tests failed; the running site is untouched"
fi

log "building the release"
mix release --overwrite >/dev/null || die "release build"

log "migrating"
"$APP_DIR/_build/prod/rel/csuite_finder/bin/migrate" || die "migration"

log "restarting $SERVICE"
systemctl restart "$SERVICE"

# Give it a moment, then check it actually came up. A deploy that leaves the
# site down and says nothing is worse than one that never ran.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    log "healthy at ${remote_sha:0:8}"
    exit 0
  fi
  log "  health check $attempt/10 not yet"
done

die "deployed ${remote_sha:0:8} but the health check never passed — check: journalctl -u $SERVICE -n 50"
