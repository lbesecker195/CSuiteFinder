# Deploying CSuiteFinder

Ubuntu VPS, nginx in front, Let's Encrypt for TLS, systemd to keep it running.

## The short way

```bash
sudo bash deploy/install.sh --domain api.example.com --email you@example.com
```

That does everything below in one pass: packages (including the full Erlang OTP
set), swap if the box is small, the service user, Postgres with a **generated**
password, `/etc/csuite-finder.env` with generated secrets, the release build,
migrations, systemd, nginx, certbot and ufw. It is safe to re-run — it keeps
secrets it has already generated and only restarts what it changed, so it
doubles as the redeploy command:

```bash
git pull && sudo bash deploy/install.sh --yes
```

On a re-run it reads the domain and Let's Encrypt address back out of
`/etc/csuite-finder.env`, so a redeploy needs no arguments and asks nothing. It
also skips certbot when a certificate is already in place — renewal is the
certbot timer's job, not the installer's.

Useful flags: `--no-ssl` (DNS not pointed here yet), `--db-socket` (no database
password at all — see below), `--treg-token <token>`, `--yes` (never prompt).

The rest of this document is what the script does, step by step, for when you
want to do it by hand or something went wrong.

## "I never set a Postgres password"

You do not need to have. Three ways this resolves:

1. **Let the installer handle it.** `install.sh` generates a random password,
   creates the role with it, and writes it into `DATABASE_URL` in the env file.
   You never see or type it. This is the default and the recommended path.

2. **Set one yourself**, if you created the role by hand:

   ```bash
   sudo -u postgres psql -c "ALTER ROLE csuite WITH PASSWORD 'somethingstrong';"
   ```

   Then put it in `DATABASE_URL`. Note that if you ran the `CREATE ROLE`
   command from step 0 verbatim, the password is literally `CHANGEME`.

3. **Use no password at all**, over the Unix socket with Postgres *peer*
   authentication. Run the installer with `--db-socket`, or set these instead
   of `DATABASE_URL`:

   ```
   DATABASE_SOCKET_DIR=/var/run/postgresql
   DATABASE_NAME=csuite_finder_prod
   DATABASE_USER=csuite
   ```

   This works because peer auth trusts the OS user, and the service runs as
   `csuite`. It cannot be written as a URL: Ecto requires a host in `url:` and
   rejects a hostless one outright, `?socket_dir=` notwithstanding — which is
   why it has its own variables.

   For peer auth the OS user must exist and match the role name, which the
   installer's `csuite` user already does.

Whichever you pick, a fresh `apt install postgresql` on Ubuntu uses `peer` for
socket connections and `scram-sha-256` for TCP to localhost — so connecting to
`localhost:5432` *without* a password will always fail, and that is expected.

---

Paths below assume the app lives at `/var/www/HoneyTrap/CSuiteFInder`.

## On pm2 — you don't want it

pm2 is a Node.js process manager. It *can* babysit any executable, but it is
the wrong tool here and adds a moving part that earns nothing:

- An OTP release already has a supervision tree. Processes that crash are
  restarted inside the VM, by the VM, in milliseconds. pm2 only sees the whole
  VM exit — which is exactly what systemd sees, for free.
- pm2 needs Node installed and running as a daemon of its own, purely to watch
  a process that is not a Node process.
- systemd gives you boot-time start, dependency ordering against Postgres,
  journald logging, and sandboxing (`ProtectSystem`, `NoNewPrivileges`) with no
  extra software.

Use the unit in `deploy/csuite-finder.service`. Everything below assumes that.

---

## 0. PostgreSQL — the current blocker

`connection refused` on `localhost:5432` means nothing is listening: Postgres
is not installed or not running on that box.

```bash
sudo apt update
sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql
sudo systemctl status postgresql --no-pager
```

Confirm it is actually listening before going further:

```bash
sudo ss -lntp | grep 5432
```

Create the role and database. Pick a real password:

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE csuite WITH LOGIN PASSWORD 'CHANGEME';
CREATE DATABASE csuite_finder_prod OWNER csuite;
SQL
```

The first migration creates the `citext` and `pgcrypto` extensions, which
requires superuser on most installs. Grant it for the migration, or create the
extensions yourself now:

```bash
sudo -u postgres psql -d csuite_finder_prod <<'SQL'
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL
```

## 1. A user to run as

Do not run the app as root.

```bash
sudo adduser --system --group --home /var/www/HoneyTrap csuite
sudo chown -R csuite:csuite /var/www/HoneyTrap
```

## 2. Environment

```bash
sudo cp deploy/csuite-finder.env.example /etc/csuite-finder.env
sudo chown root:root /etc/csuite-finder.env
sudo chmod 600 /etc/csuite-finder.env
sudo nano /etc/csuite-finder.env
```

Fill in at minimum `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `TREG_TOKEN`
and `ADMIN_TOKEN`.

`ANTHROPIC_API_KEY` is optional. It buys a last-resort answer when a provider
has already missed — a job title, or a company's email pattern — capped at 8
and 10 output tokens respectively. Unset, that fallback is skipped and nothing
else changes.

`DATABASE_URL` is a **full connection URL**, not a host and port:

```
DATABASE_URL=ecto://csuite:s3cret@localhost/csuite_finder_prod
             ^^^^   ^^^^^^ ^^^^^^ ^^^^^^^^^ ^^^^^^^^^^^^^^^^^^
             scheme user   password host    database
```

If the password contains `@ : / ?`, percent-encode it — a raw `@` splits the URL
at the wrong place. Generate the secrets on the box:

```bash
mix phx.gen.secret          # SECRET_KEY_BASE
openssl rand -hex 32        # ADMIN_TOKEN
```

For treg, prefer a dedicated agent token over your personal one — it can be
capped and revoked without touching your own access:

```bash
treg org agent-new csuite-prod
```

## 3. Build the release

```bash
cd /var/www/HoneyTrap/CSuiteFInder
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix release --overwrite
```

Two binaries, and the difference matters:

- **`bin/server`** starts the app *with the HTTP endpoint*. This is what systemd
  runs and what you want.
- **`bin/csuite_finder start`** starts the app without the web server, because
  it does not set `PHX_SERVER=true`. Useful for running release tasks; it will
  look like a silent success with nothing listening on port 4000.

Run the migrations. The release carries its own migrator, so Mix is not needed
at runtime:

```bash
set -a && . /etc/csuite-finder.env && set +a
_build/prod/rel/csuite_finder/bin/migrate
```

Seed a demo account if you want one (optional — registration works over HTTP):

```bash
_build/prod/rel/csuite_finder/bin/csuite_finder eval \
  'CsuiteFinder.Accounts.register(%{email: "you@yourdomain.com"}) |> IO.inspect()'
```

## 4. systemd

```bash
sudo cp deploy/csuite-finder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now csuite-finder
sudo systemctl status csuite-finder --no-pager
journalctl -u csuite-finder -f
```

It should be listening on loopback only:

```bash
curl -s localhost:4000/csuitefinder/health
sudo ss -lntp | grep 4000        # expect 127.0.0.1:4000, not 0.0.0.0:4000
```

## 5. nginx

```bash
sudo apt install -y nginx
sudo cp deploy/nginx-csuite-finder.conf /etc/nginx/sites-available/csuite-finder
sudo nano /etc/nginx/sites-available/csuite-finder   # set server_name
sudo ln -s /etc/nginx/sites-available/csuite-finder /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

**`proxy_set_header X-Forwarded-Proto $scheme;` is not optional.** The app runs
with `force_ssl: [rewrite_on: [:x_forwarded_proto]]`, so without that header it
believes every request arrived in plaintext and redirects to HTTPS forever. The
symptom is `ERR_TOO_MANY_REDIRECTS` and it looks like a broken app when it is
only a mis-proxied one.

## 6. TLS

Point an A record at the box first — certbot validates over HTTP and will fail
if DNS has not propagated.

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d api.example.com --agree-tos -m you@yourdomain.com --redirect
```

Certbot edits the nginx file in place: it adds the `listen 443 ssl` block, the
certificate paths, and a permanent redirect from port 80. Renewal is installed
as a systemd timer; check it:

```bash
sudo systemctl list-timers | grep certbot
sudo certbot renew --dry-run
```

## 7. Firewall

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
sudo ufw status
```

Port 4000 is deliberately absent — the app binds loopback, and nginx is the
only way in.

## 8. Verify

```bash
curl -s https://api.example.com/csuitefinder/health | jq
curl -s https://api.example.com/csuitefinder/pricing | jq

# Register and make a real lookup.
KEY=$(curl -s -X POST https://api.example.com/csuitefinder/register \
  -H 'content-type: application/json' \
  -d '{"email":"you@yourdomain.com"}' | jq -r .api_key)

curl -s -H "Authorization: Bearer $KEY" \
  "https://api.example.com/csuitefinder/email/find?full_name=Jensen%20Huang&domain=nvidia.com" | jq
```

Then open `https://api.example.com/admin?token=$ADMIN_TOKEN`.

## 9. PayPal webhook

In the PayPal developer dashboard, point the webhook at:

```
https://api.example.com/csuitefinder/billing/webhook
```

Subscribe to `CHECKOUT.ORDER.APPROVED` and `PAYMENT.CAPTURE.COMPLETED`, then
put the webhook id in `PAYPAL_WEBHOOK_ID` and restart. Without that id the
signature check cannot pass and every webhook is dropped — which is the correct
failure, but it is silent, so check `journalctl` after the first payment.

---

## Redeploying

```bash
cd /var/www/HoneyTrap/CSuiteFInder
git pull
export MIX_ENV=prod
mix deps.get --only prod
mix release --overwrite
set -a && . /etc/csuite-finder.env && set +a
_build/prod/rel/csuite_finder/bin/migrate
sudo systemctl restart csuite-finder
```

## Operating it

```bash
journalctl -u csuite-finder -f                  # logs
journalctl -u csuite-finder --since "1 hour ago" -p err
sudo systemctl restart csuite-finder

# Attach a console to the running system (careful — it is a live shell).
sudo -u csuite _build/prod/rel/csuite_finder/bin/csuite_finder remote
```

Back up the database. The cache is the asset — patterns you have already paid
for, and the addresses built from them:

```bash
sudo -u postgres pg_dump csuite_finder_prod | gzip > csuite-$(date +%F).sql.gz
```

## Sizing

A $5 box is fine. The app is I/O-bound on provider calls, not CPU-bound, and
Postgres holds the whole cache in a few hundred MB for a long while. If the box
has 1 GB of RAM, add swap before building — `mix release` compiling Bandit and
Phoenix together can exceed it:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `connection refused` on 5432 | Postgres not installed or not started — step 0 |
| `ERR_TOO_MANY_REDIRECTS` | nginx is not sending `X-Forwarded-Proto` |
| `SECRET_KEY_BASE is missing` | `EnvironmentFile` not read; check the path and that it has no `export` lines |
| `DATABASE_URL is not a database URL` | You gave a host:port pair. It needs `ecto://USER:PASSWORD@HOST/DATABASE`, or use `DATABASE_SOCKET_DIR` for no password |
| `password authentication failed` | The role has a different password than `DATABASE_URL` says. Reset it: `sudo -u postgres psql -c "ALTER ROLE csuite WITH PASSWORD '...'"` |
| `no password supplied` | You are connecting over TCP with no password. Either set one, or switch to `DATABASE_SOCKET_DIR` |
| App starts but nothing listens on 4000 | You ran `bin/csuite_finder start` instead of `bin/server` — only the latter sets `PHX_SERVER=true` |
| `/admin` returns 503 | `ADMIN_TOKEN` is unset — deliberate, set it and restart |
| `can't find include lib "public_key/include/public_key.hrl"` | Erlang installed without its full OTP set; install `esl-erlang`, or `erlang-dev erlang-public-key erlang-ssl erlang-crypto erlang-asn1` |
| Lookups return `treg_configured: false` | `TREG_TOKEN` not in the environment file |
| Enrichment never fills in a job title | `ANTHROPIC_API_KEY` unset — the fallback is skipped silently, by design |
