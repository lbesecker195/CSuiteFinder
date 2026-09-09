#!/usr/bin/env bash
#
# CSuiteFinder — one-shot installer for Ubuntu/Debian.
#
#   sudo bash deploy/install.sh --domain api.example.com --email you@example.com
#
# Safe to re-run: it preserves secrets it has already generated, skips work
# that is already done, and only restarts what it changed.
#
# Flags (all optional — you will be prompted for what is missing):
#   --domain <fqdn>       public hostname, e.g. api.example.com
#   --email <addr>        contact address for Let's Encrypt
#   --treg-token <token>  from `treg org agent-new csuite-prod`
#   --no-ssl              skip certbot (use when DNS is not pointed here yet)
#   --no-firewall         skip ufw
#   --db-socket           connect to Postgres over the Unix socket, no password
#   --yes                 never prompt; fail instead of asking

set -euo pipefail

APP_NAME=csuite_finder
SERVICE=csuite-finder
ENV_FILE=/etc/csuite-finder.env
APP_USER=csuite
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME=csuite_finder_prod
DB_USER=csuite
PORT=4000

DOMAIN=""; LE_EMAIL=""; TREG_TOKEN_ARG=""
DO_SSL=1; DO_FIREWALL=1; USE_SOCKET=0; ASSUME_YES=0

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)      DOMAIN="${2:?}"; shift 2 ;;
    --email)       LE_EMAIL="${2:?}"; shift 2 ;;
    --treg-token)  TREG_TOKEN_ARG="${2:?}"; shift 2 ;;
    --no-ssl)      DO_SSL=0; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    --db-socket)   USE_SOCKET=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *)             die "unknown flag: $1" ;;
  esac
done

ask() { # ask <var> <prompt> [default]
  local __var=$1 __prompt=$2 __reply
  local __has_default=0 __default=""
  # An empty default passed on purpose ("" means: blank is a valid answer) is
  # not the same as no default at all. $# is what tells them apart.
  if [[ $# -ge 3 ]]; then __has_default=1; __default=$3; fi

  # :- guards an entirely undeclared name, which would otherwise trip `set -u`
  # and report "unbound variable" instead of the message we want.
  if [[ -n "${!__var:-}" ]]; then return; fi

  if [[ $ASSUME_YES -eq 1 ]]; then
    if [[ $__has_default -eq 1 ]]; then
      printf -v "$__var" '%s' "$__default"
      return
    fi
    die "--yes was given but $__var is not set (pass it as a flag)"
  fi

  read -rp "    $__prompt${__default:+ [$__default]}: " __reply
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

# On a re-run, reuse what we configured last time so a redeploy needs no input.
load_existing_config() {
  [[ -f "$ENV_FILE" ]] || return 0
  local prev_host prev_email
  prev_host="$(sed -n 's/^PHX_HOST=//p' "$ENV_FILE" | head -1)"
  prev_email="$(sed -n 's/^LETSENCRYPT_EMAIL=//p' "$ENV_FILE" | head -1)"
  [[ -z "$DOMAIN"   && -n "$prev_host"  ]] && DOMAIN="$prev_host"
  [[ -z "$LE_EMAIL" && -n "$prev_email" ]] && LE_EMAIL="$prev_email"
  return 0
}

# ---------------------------------------------------------------- preflight

step "Preflight"
[[ $EUID -eq 0 ]] || die "run with sudo: sudo bash deploy/install.sh"
[[ -f "$APP_DIR/mix.exs" ]] || die "cannot find mix.exs — run this from inside the app checkout"
command -v apt-get >/dev/null || die "this installer targets Debian/Ubuntu"
ok "app directory: $APP_DIR"

load_existing_config
if [[ -n "$DOMAIN" ]]; then
  ok "reusing existing configuration for $DOMAIN"
fi

ask DOMAIN "Public domain (blank for IP-only, no SSL)" ""
if [[ -z "$DOMAIN" ]]; then
  DO_SSL=0
  DOMAIN="$(hostname -I 2>/dev/null | awk '{print $1}')"
  warn "no domain given — SSL disabled, using $DOMAIN"
fi
[[ $DO_SSL -eq 1 ]] && ask LE_EMAIL "Email for Let's Encrypt" ""
[[ $DO_SSL -eq 1 && -z "$LE_EMAIL" ]] && { DO_SSL=0; warn "no email — skipping SSL"; }

# --------------------------------------------------------------- packages

step "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  postgresql postgresql-contrib nginx curl ca-certificates openssl \
  build-essential git jq >/dev/null
ok "postgresql, nginx, build tools"

# Erlang must carry its full OTP set; a stripped erlang-base cannot compile
# mint's TLS shim (public_key/include/public_key.hrl).
need_erlang=1
if command -v erl >/dev/null 2>&1; then
  if erl -noshell -eval 'case code:lib_dir(public_key) of {error,_} -> halt(1); _ -> halt(0) end' 2>/dev/null; then
    need_erlang=0
  else
    warn "Erlang is installed but missing public_key — reinstalling the full set"
  fi
fi

if [[ $need_erlang -eq 1 ]] || ! command -v elixir >/dev/null 2>&1; then
  if ! apt-get install -y -qq erlang-nox erlang-dev elixir >/dev/null 2>&1; then
    warn "distro packages insufficient — using Erlang Solutions"
    curl -fsSL "https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb" -o /tmp/esl.deb
    apt-get install -y -qq /tmp/esl.deb >/dev/null
    apt-get update -qq
    apt-get install -y -qq esl-erlang elixir >/dev/null
  fi
fi
erl -noshell -eval 'case code:lib_dir(public_key) of {error,_} -> halt(1); _ -> halt(0) end' \
  || die "Erlang still lacks public_key; install esl-erlang manually"
ok "erlang $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().') · $(elixir --version | tail -1)"

# ------------------------------------------------------------------- swap

step "Checking memory"
mem_mb=$(free -m | awk '/^Mem:/{print $2}')
swap_mb=$(free -m | awk '/^Swap:/{print $2}')
if [[ $mem_mb -lt 2048 && $swap_mb -lt 1024 ]]; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "added 2G swap (${mem_mb}MB RAM would not survive the build)"
  fi
else
  ok "${mem_mb}MB RAM, ${swap_mb}MB swap"
fi

# ------------------------------------------------------------------- user

step "Service user"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  adduser --system --group --home "$(dirname "$APP_DIR")" --no-create-home "$APP_USER"
  ok "created user $APP_USER"
else
  ok "user $APP_USER exists"
fi

# --------------------------------------------------------------- postgres

step "PostgreSQL"
systemctl enable --now postgresql >/dev/null 2>&1 || true
for _ in $(seq 1 15); do
  sudo -u postgres psql -tAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done
sudo -u postgres psql -tAc 'SELECT 1' >/dev/null 2>&1 || die "postgres is not accepting connections"

role_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")
db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")

# Preserve an existing password across re-runs; otherwise generate one, so
# "I never set a password" is never a thing the operator has to solve.
if [[ -f "$ENV_FILE" ]] && grep -q '^DATABASE_URL=' "$ENV_FILE"; then
  DB_PASS="$(grep '^DATABASE_URL=' "$ENV_FILE" | sed -n 's#.*://[^:]*:\([^@]*\)@.*#\1#p')"
fi
DB_PASS="${DB_PASS:-$(openssl rand -hex 24)}"

if [[ "$role_exists" != "1" ]]; then
  sudo -u postgres psql -qc "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';" >/dev/null
  ok "created role $DB_USER (password generated)"
else
  sudo -u postgres psql -qc "ALTER ROLE $DB_USER WITH PASSWORD '$DB_PASS';" >/dev/null
  ok "role $DB_USER exists (password synced)"
fi

if [[ "$db_exists" != "1" ]]; then
  sudo -u postgres psql -qc "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null
  ok "created database $DB_NAME"
else
  ok "database $DB_NAME exists"
fi

# The first migration needs these, and creating an extension requires superuser.
sudo -u postgres psql -qd "$DB_NAME" \
  -c 'CREATE EXTENSION IF NOT EXISTS citext;' \
  -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;' >/dev/null
ok "citext + pgcrypto ready"

if [[ $USE_SOCKET -eq 1 ]]; then
  SOCKET_DIR="$(sudo -u postgres psql -tAc 'SHOW unix_socket_directories' | cut -d, -f1 | xargs)"
  SOCKET_DIR="${SOCKET_DIR:-/var/run/postgresql}"
  ok "using unix socket at $SOCKET_DIR (no password)"
fi

# -------------------------------------------------------------- environment

step "Environment file"
if [[ -f "$ENV_FILE" ]]; then
  ok "$ENV_FILE exists — keeping its secrets"
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
  ADMIN_TOKEN="${ADMIN_TOKEN:-$(openssl rand -hex 32)}"
  SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 48 | tr -d '\n')}"
else
  ADMIN_TOKEN="$(openssl rand -hex 32)"
  SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
fi

TREG_TOKEN="${TREG_TOKEN_ARG:-${TREG_TOKEN:-}}"
if [[ -z "$TREG_TOKEN" && $ASSUME_YES -eq 0 ]]; then
  echo "    A treg token is what pays for lookups. Get one with:"
  echo "        treg org agent-new csuite-prod"
  ask TREG_TOKEN "treg token (blank to add later)" ""
fi

if [[ $USE_SOCKET -eq 1 ]]; then
  DB_LINES="DATABASE_SOCKET_DIR=$SOCKET_DIR
DATABASE_NAME=$DB_NAME
DATABASE_USER=$DB_USER"
else
  DB_LINES="DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME"
fi

umask 077
cat > "$ENV_FILE" <<ENV
# Written by deploy/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# systemd reads this directly: no quotes, no export, no shell expansion.
MIX_ENV=prod
PHX_SERVER=true
PORT=$PORT
PHX_HOST=$DOMAIN
LETSENCRYPT_EMAIL=${LE_EMAIL:-}

$DB_LINES

SECRET_KEY_BASE=$SECRET_KEY_BASE
ADMIN_TOKEN=$ADMIN_TOKEN

TREG_TOKEN=$TREG_TOKEN
TREG_ORG=${TREG_ORG:-}

PAYPAL_MODE=${PAYPAL_MODE:-sandbox}
PAYPAL_CLIENT_ID=${PAYPAL_CLIENT_ID:-}
PAYPAL_CLIENT_SECRET=${PAYPAL_CLIENT_SECRET:-}
PAYPAL_WEBHOOK_ID=${PAYPAL_WEBHOOK_ID:-}

POOL_SIZE=${POOL_SIZE:-10}
ENV
# root:APP_USER 640 — systemd reads it as root, and the service user can read
# its own config to run release tasks by hand. Never world-readable.
chown "root:$APP_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok "wrote $ENV_FILE (root:$APP_USER, 640)"

# ------------------------------------------------------------------- build

step "Building the release (this is the slow part)"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
# HOME inside the app tree: it is the directory we just chowned, so hex and
# rebar caches land somewhere the service user can actually write.
sudo -u "$APP_USER" env HOME="$APP_DIR" MIX_ENV=prod bash -c "
  set -e
  cd '$APP_DIR'
  mix local.hex --force --if-missing >/dev/null 2>&1 || mix local.hex --force >/dev/null
  mix local.rebar --force >/dev/null
  mix deps.get --only prod >/dev/null
  mix release --overwrite >/dev/null
"
ok "release built"

step "Running migrations"
# Source the env file inside the child shell. Passing it through `xargs` would
# split SECRET_KEY_BASE on the / + = that base64 produces.
sudo -u "$APP_USER" env HOME="$APP_DIR" bash -c '
  set -a; . "$1"; set +a
  exec "$2"
' _ "$ENV_FILE" "$APP_DIR/_build/prod/rel/$APP_NAME/bin/migrate"
ok "database migrated"

# ----------------------------------------------------------------- systemd

step "systemd service"
sed -e "s#/var/www/HoneyTrap/CSuiteFInder#$APP_DIR#g" \
    -e "s#^User=.*#User=$APP_USER#" \
    -e "s#^Group=.*#Group=$APP_USER#" \
    "$APP_DIR/deploy/$SERVICE.service" > "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"
sleep 4
systemctl is-active --quiet "$SERVICE" \
  || { journalctl -u "$SERVICE" -n 30 --no-pager; die "service failed to start"; }
ok "$SERVICE running"

for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:$PORT/csuitefinder/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/csuitefinder/health" >/dev/null 2>&1 \
  || die "app is up but not answering on port $PORT"
ok "health check passed"

# ------------------------------------------------------------------- nginx

step "nginx"
sed "s/api.example.com/$DOMAIN/g" "$APP_DIR/deploy/nginx-$SERVICE.conf" \
  > "/etc/nginx/sites-available/$SERVICE"
ln -sf "/etc/nginx/sites-available/$SERVICE" "/etc/nginx/sites-enabled/$SERVICE"
rm -f /etc/nginx/sites-enabled/default
mkdir -p /var/www/html
nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx config rejected"; }
systemctl reload nginx
ok "proxying $DOMAIN -> 127.0.0.1:$PORT"

# --------------------------------------------------------------------- ssl

if [[ $DO_SSL -eq 1 ]]; then
  step "TLS certificate"
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    ok "certificate already present; renewal is handled by the certbot timer"
    DO_SSL=1
    SKIP_CERTBOT=1
  fi
  if [[ "${SKIP_CERTBOT:-0}" == "1" ]]; then
    resolved=""; public_ip=""
  else
  resolved="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
  public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$resolved" && -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
    warn "$DOMAIN resolves to $resolved but this box is $public_ip"
    warn "certbot will fail — fix DNS then run: certbot --nginx -d $DOMAIN"
  else
    if certbot --nginx -d "$DOMAIN" --agree-tos -m "$LE_EMAIL" \
         --redirect --non-interactive >/dev/null 2>&1; then
      ok "certificate issued; renewal timer installed"
    else
      warn "certbot failed — the app is live over HTTP; retry with:"
      warn "  certbot --nginx -d $DOMAIN --agree-tos -m $LE_EMAIL --redirect"
      DO_SSL=0
    fi
  fi
  fi
fi

# ---------------------------------------------------------------- firewall

if [[ $DO_FIREWALL -eq 1 ]] && command -v ufw >/dev/null; then
  step "Firewall"
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 'Nginx Full' >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  ok "ssh + http/https open; port $PORT stays loopback-only"
fi

# ----------------------------------------------------------------- summary

scheme=$([[ $DO_SSL -eq 1 ]] && echo https || echo http)
base="$scheme://$DOMAIN"

step "Done"
cat <<SUMMARY

  $(bold "CSuiteFinder is live at $base")

  Landing page   $base/
  Health         $base/csuitefinder/health
  Admin          $base/admin?token=$ADMIN_TOKEN

  Admin token    $ADMIN_TOKEN
  Secrets        $ENV_FILE  (root only)

  Get an API key:

    curl -X POST $base/csuitefinder/register \\
      -H 'content-type: application/json' \\
      -d '{"email":"you@yourdomain.com"}'

  Logs      journalctl -u $SERVICE -f
  Restart   systemctl restart $SERVICE
  Redeploy  git pull && sudo bash deploy/install.sh --yes

SUMMARY

if [[ -z "$TREG_TOKEN" ]]; then
  warn "TREG_TOKEN is empty — lookups will fail until you add one:"
  warn "  sudo nano $ENV_FILE && sudo systemctl restart $SERVICE"
fi
