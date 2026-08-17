#!/usr/bin/env bash
#
# DialerPortal DP Switch — one-command installer for a fresh Debian 13 (trixie) host.
#
#   curl -fsSL https://raw.githubusercontent.com/dialerportal/dp-switch/main/install.sh | sudo bash
#
# Installs & wires: Kamailio 6.0 (public SIP edge) + FreeSWITCH 1.11 (media) +
# Laravel portal (nginx + PHP 8.3 + MariaDB) + fail2ban + nftables + TLS.
# Prompts for: domain, Let's Encrypt email, SignalWire token (FreeSWITCH repo).
# Every DB password / shared secret / ESL password / admin password is generated
# fresh on this machine and never leaves it.
#
set -euo pipefail

REPO_SLUG="dialerportal/dp-switch"
REPO_URL="https://github.com/${REPO_SLUG}.git"
BRANCH="main"
CLONE_DIR="/opt/dp-switch"
CRED_DIR="/root/.dpswitch"
APP_DIR="/var/www/dpswitch"

c()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
step(){ c "1;36" "==> $*"; }
ok()  { c "1;32" "  ok $*"; }
warn(){ c "1;33" "  !! $*"; }
die() { c "1;31" "FATAL: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (use sudo)."

# ---------------------------------------------------------------- inputs (asked up front)
DOMAIN="${DOMAIN:-}"; LE_EMAIL="${LE_EMAIL:-}"; SIGNALWIRE_TOKEN="${SIGNALWIRE_TOKEN:-}"; OPEN_SIP="${OPEN_SIP:-}"
while [ $# -gt 0 ]; do case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --email) LE_EMAIL="$2"; shift 2;;
    --signalwire-token) SIGNALWIRE_TOKEN="$2"; shift 2;;
    --open-sip) OPEN_SIP=yes; shift;;
    --no-open-sip) OPEN_SIP=no; shift;;
    *) shift;;
esac; done

# On a re-run, reuse the domain/email/open-sip choices already saved, so the
# operator isn't re-prompted after a mid-way failure.
SAVED="${CRED_DIR}/install-credentials"
if [ -f "$SAVED" ]; then
    [ -n "$DOMAIN" ]   || DOMAIN="$(grep -E '^DOMAIN=' "$SAVED" | cut -d= -f2-)"
    [ -n "$LE_EMAIL" ] || LE_EMAIL="$(grep -E '^LE_EMAIL=' "$SAVED" | cut -d= -f2-)"
    [ -n "$OPEN_SIP" ] || OPEN_SIP="$(grep -E '^OPEN_SIP=' "$SAVED" | cut -d= -f2-)"
fi

# Unattended runs (nohup, cron, `| bash` from a pipe) have no controlling
# terminal: reading /dev/tty there fails loudly and returns nothing. Detect that
# once, so a missing answer becomes a clear error or a documented default rather
# than a "No such device or address" line followed by an empty value.
have_tty() { [ -e /dev/tty ] && { : </dev/tty; } 2>/dev/null; }
ask()    { local p="$1" d="${2:-}" v; have_tty || { echo "$d"; return; }; if [ -n "$d" ]; then read -rp "$p [$d]: " v </dev/tty || true; echo "${v:-$d}"; else read -rp "$p: " v </dev/tty || true; echo "$v"; fi; }
asksec() { local p="$1" v; have_tty || { echo ""; return; }; read -rsp "$p: " v </dev/tty || true; echo >/dev/tty; echo "$v"; }   # hidden entry for tokens

# Prompt for anything still unknown, BEFORE cloning, so the re-exec never re-asks.
[ -n "$DOMAIN" ]           || DOMAIN="$(ask 'SIP + portal domain (e.g. sbc.example.com)')"
[ -n "$LE_EMAIL" ]         || LE_EMAIL="$(ask 'Email for Lets Encrypt / expiry notices')"
[ -n "$SIGNALWIRE_TOKEN" ] || SIGNALWIRE_TOKEN="$(asksec 'SignalWire access token (free from signalwire.com; for the FreeSWITCH repo)')"
if [ -z "$OPEN_SIP" ]; then
    if have_tty; then a="$(ask 'Open SIP (5060/5061/RTP) to the public internet now? y/N' 'N')"; [ "${a,,}" = y ] && OPEN_SIP=yes || OPEN_SIP=no
    else OPEN_SIP=no; warn "no terminal to ask about public SIP — defaulting to closed (pass --open-sip to change)"; fi
fi
[ -n "$DOMAIN" ] || die "domain is required."
[ -n "$SIGNALWIRE_TOKEN" ] || die "SignalWire token is required for FreeSWITCH."
export DOMAIN LE_EMAIL SIGNALWIRE_TOKEN OPEN_SIP

# ---------------------------------------------------------------- self-bootstrap
# First run is usually just this one file (fetched via `curl -O`); the rest of
# the repo isn't on disk yet. Clone it, then re-exec. Inputs are exported, so
# the re-exec never re-prompts. Re-running after a failure just `git pull`s.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -z "${SELF_DIR}" ] || [ ! -d "${SELF_DIR}/server" ]; then
    step "fetching installer repo -> ${CLONE_DIR}"
    export DEBIAN_FRONTEND=noninteractive
    # Only touch apt if git is actually missing — avoids re-tripping any stale
    # third-party repo error just to fetch a tool that's usually already present.
    # NB: do NOT try to narrow this update with `-o Dir::Etc::sourceparts=/dev/null`.
    # Debian 13 ships no /etc/apt/sources.list at all — every repo is a deb822
    # file under /etc/apt/sources.list.d/ — so that option leaves apt with zero
    # sources, `update` still exits 0, and the install then fails with
    # "Unable to locate package git".
    if ! command -v git >/dev/null 2>&1; then
        apt-get update -qq || die "apt-get update failed — cannot fetch git to clone the installer repo."
        apt-get install -y -qq git >/dev/null || die "could not install git — see the apt output above."
    fi
    if [ -d "${CLONE_DIR}/.git" ]; then git -C "${CLONE_DIR}" pull -q || true; else git clone -q --depth 1 -b "${BRANCH}" "${REPO_URL}" "${CLONE_DIR}"; fi
    exec bash "${CLONE_DIR}/install.sh"
fi
REPO="${SELF_DIR}"

PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(hostname -I | awk '{print $1}')"
step "domain=$DOMAIN  public-ip=$PUBLIC_IP  open-sip=$OPEN_SIP"

# ---------------------------------------------------------------- secrets (idempotent)
step "resolving secrets"
mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"; umask 077
gen()  { openssl rand -hex "${1:-24}"; }
# read a value from the saved credentials file if this is a re-run, else blank
rc()   { [ -f "$SAVED" ] && grep -E "^$1=" "$SAVED" | head -1 | cut -d= -f2- || true; }
APP_DB_PASS="$(rc APP_DB_PASS)";      APP_DB_PASS="${APP_DB_PASS:-$(gen 18)}"
KAM_DB_PASS="$(rc KAM_DB_PASS)";      KAM_DB_PASS="${KAM_DB_PASS:-$(gen 18)}"
SWITCH_SECRET="$(rc SWITCH_SHARED_SECRET)"; SWITCH_SECRET="${SWITCH_SECRET:-$(gen 24)}"
ESL_PASSWORD="$(rc ESL_PASSWORD)";    ESL_PASSWORD="${ESL_PASSWORD:-$(gen 20)}"
ADMIN_PASSWORD="$(rc ADMIN_PASSWORD)";ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen 12)}"
ADMIN_EMAIL="$(rc ADMIN_EMAIL)";      ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
APP_KEY="$(rc APP_KEY)";              APP_KEY="${APP_KEY:-base64:$(openssl rand -base64 32)}"
cat > "$SAVED" <<EOF
# DialerPortal DP Switch — first written $(date -u +%FT%TZ). KEEP PRIVATE. Reused on re-run.
DOMAIN=$DOMAIN
LE_EMAIL=$LE_EMAIL
OPEN_SIP=$OPEN_SIP
PORTAL_URL=https://$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_PASSWORD=$ADMIN_PASSWORD
APP_DB_USER=dpswitch
APP_DB_PASS=$APP_DB_PASS
KAM_DB_USER=kamailio
KAM_DB_PASS=$KAM_DB_PASS
SWITCH_SHARED_SECRET=$SWITCH_SECRET
ESL_PASSWORD=$ESL_PASSWORD
APP_KEY=$APP_KEY
EOF
ok "secrets in $SAVED (0600) — regenerated only if missing"

# ---------------------------------------------------------------- apt repos + packages
step "configuring apt repositories"
export DEBIAN_FRONTEND=noninteractive
install -d -m 0755 /usr/share/keyrings
apt-get install -y -qq curl gnupg ca-certificates lsb-release apt-transport-https >/dev/null
# Install a signing key as a world-readable binary keyring. Debian 13 verifies
# with sqv running as the unprivileged _apt user, so the keyring MUST be 0644
# (an earlier umask left these 0600 => "Permission denied / not signed"). Armored
# keys are dearmored; already-binary keys are copied as-is.
install_key() { # url dest [curl-extra-args...]
    local url="$1" dest="$2"; shift 2
    local tmp; tmp="$(mktemp)"
    curl -fsSL "$@" "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
    if head -c 40 "$tmp" | grep -q 'BEGIN PGP'; then gpg --dearmor < "$tmp" > "$dest"; else cp "$tmp" "$dest"; fi
    chmod 0644 "$dest"; rm -f "$tmp"
}
addsrc() { echo "$2" > "/etc/apt/sources.list.d/$1"; chmod 0644 "/etc/apt/sources.list.d/$1"; }
# PHP (sury)
install_key https://packages.sury.org/php/apt.gpg /usr/share/keyrings/sury-php.gpg || die "could not fetch the sury PHP signing key"
addsrc php.list "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ trixie main"
# Kamailio 6.0
install_key http://deb.kamailio.org/kamailiodebkey.gpg /usr/share/keyrings/kamailio-archive.gpg || die "could not fetch the Kamailio signing key"
addsrc kamailio.list "deb [signed-by=/usr/share/keyrings/kamailio-archive.gpg] http://deb.kamailio.org/kamailio60 trixie main"
# FreeSWITCH (SignalWire, token-gated)
install_key https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg /usr/share/keyrings/signalwire-freeswitch-repo.gpg --user "signalwire:${SIGNALWIRE_TOKEN}" \
    || die "SignalWire token rejected — check it at signalwire.com."
# auth.conf carries the token: stays root-only 0600 (read by apt as root, not _apt)
echo "machine freeswitch.signalwire.com login signalwire password ${SIGNALWIRE_TOKEN}" > /etc/apt/auth.conf.d/freeswitch.conf
chmod 600 /etc/apt/auth.conf.d/freeswitch.conf
addsrc freeswitch.list "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ trixie main"

step "updating apt indexes"
apt-get update || die "apt-get update failed — check the repository errors above."
step "installing packages — FreeSWITCH is large, this can take several minutes (progress shown below)"
# NOTE: not silenced on purpose — the operator sees the download/unpack progress
# so a long FreeSWITCH pull doesn't look like a hang.
apt-get install -y \
    nginx mariadb-server \
    php8.3-fpm php8.3-cli php8.3-mysql php8.3-mbstring php8.3-xml php8.3-curl php8.3-bcmath php8.3-zip php8.3-intl php8.3-gd \
    kamailio kamailio-mysql-modules kamailio-tls-modules \
    freeswitch-meta-all freeswitch-conf-vanilla \
    certbot fail2ban nftables composer jq sudo logrotate || die "package install failed — see apt output above."
# our FreeSWITCH overlay references vanilla macros ($${domain}, loopback.auto, etc.) —
# the base config must be present or FreeSWITCH won't parse its XML at all.
[ -f /etc/freeswitch/freeswitch.xml ] && [ -f /etc/freeswitch/vars.xml ] || die "FreeSWITCH base config (freeswitch-config-vanilla) missing"
# fail loudly if anything critical is missing rather than limping on
for bin in nginx mariadbd php8.3 kamailio freeswitch composer; do
    command -v "$bin" >/dev/null 2>&1 || [ -x "/usr/sbin/$bin" ] || dpkg -s "${bin%%[0-9]*}" >/dev/null 2>&1 \
        || warn "expected component '$bin' not found on PATH — check its package"
done
ok "packages installed"

# ---------------------------------------------------------------- databases
step "creating databases + users"
systemctl enable --now mariadb >/dev/null 2>&1 || true
mysql() { command mariadb "$@"; }
# CREATE ... IF NOT EXISTS + ALTER USER keeps this safe to re-run and guarantees
# the user passwords match the (reused-on-re-run) secrets.
mysql <<SQL
CREATE DATABASE IF NOT EXISTS dpswitch_app CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS switch;
CREATE DATABASE IF NOT EXISTS switchcdr;
CREATE DATABASE IF NOT EXISTS kamailio;
SQL
# Grant for BOTH 'localhost' (socket) and '127.0.0.1' (TCP): the portal .env uses
# TCP 127.0.0.1, and MariaDB treats the two hosts as distinct accounts.
for H in localhost 127.0.0.1; do
mysql <<SQL
CREATE USER IF NOT EXISTS 'dpswitch'@'$H' IDENTIFIED BY '${APP_DB_PASS}';
ALTER  USER 'dpswitch'@'$H' IDENTIFIED BY '${APP_DB_PASS}';
CREATE USER IF NOT EXISTS 'kamailio'@'$H' IDENTIFIED BY '${KAM_DB_PASS}';
ALTER  USER 'kamailio'@'$H' IDENTIFIED BY '${KAM_DB_PASS}';
GRANT ALL PRIVILEGES ON dpswitch_app.* TO 'dpswitch'@'$H';
GRANT SELECT,INSERT,UPDATE,DELETE ON switch.*    TO 'dpswitch'@'$H';
GRANT SELECT,INSERT,UPDATE,DELETE ON switchcdr.* TO 'dpswitch'@'$H';
GRANT ALL PRIVILEGES ON kamailio.* TO 'kamailio'@'$H';
FLUSH PRIVILEGES;
SQL
done
step "loading schema (only into empty databases)"
render() { sed -e "s|__PUBLIC_IP__|${PUBLIC_IP}|g" -e "s|__DOMAIN__|${DOMAIN}|g" \
               -e "s|__ESL_PASSWORD__|${ESL_PASSWORD}|g" -e "s|__SWITCH_SECRET__|${SWITCH_SECRET}|g" \
               -e "s|__KAM_DB_PASS__|${KAM_DB_PASS}|g"; }
ntables() { mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1'"; }
load_schema() { # db, file, [render]
    if [ "$(ntables "$1")" -eq 0 ]; then
        if [ "${3:-}" = render ]; then render < "$2" | mysql "$1"; else mysql "$1" < "$2"; fi
        ok "loaded schema into $1"
    else ok "$1 already has tables — skipping (preserves existing data)"; fi
}
load_schema switch       "$REPO/database/schema-switch.sql"
load_schema switchcdr    "$REPO/database/schema-switchcdr.sql"
load_schema dpswitch_app "$REPO/database/schema-dpswitch_app.sql"
load_schema kamailio     "$REPO/database/schema-kamailio.sql" render
# Kamailio's `version` rows are load-bearing (usrloc/auth_db abort without them)
# and were stripped by the --no-data dump. Upsert them UNCONDITIONALLY so both a
# fresh install and a re-run over an already-loaded (but version-empty) DB heal.
mysql kamailio < "$REPO/database/seed-kamailio-version.sql"
# seeds: only when the target table is empty (avoids duplicate-key on re-run)
[ "$(mysql -N -e "SELECT COUNT(*) FROM switch.sys_currencies" 2>/dev/null || echo 0)" -eq 0 ] && mysql switch < "$REPO/database/seed-currencies.sql" || true
[ "$(mysql -N -e "SELECT COUNT(*) FROM dpswitch_app.migrations" 2>/dev/null || echo 0)" -eq 0 ] && mysql dpswitch_app < "$REPO/database/seed-migrations.sql" || true
# table-specific grant AFTER the schema exists (the subscriber VIEW reads this table)
mysql <<SQL
GRANT SELECT ON switch.customer_sip_account TO 'kamailio'@'localhost';
GRANT SELECT ON switch.customer_sip_account TO 'kamailio'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
# The `address` view is load-bearing: without it the permissions module has no
# trusted-IP list, every IP-authenticated customer is digest-challenged, cannot
# answer, and fails with a 407 that route[AUTH] never logs. load_schema skips a
# database that already has tables, so define it UNCONDITIONALLY here (same
# reasoning as the kamailio `version` rows above) to heal upgrades as well as
# fresh installs.
mysql kamailio <<'SQL'
DROP TABLE IF EXISTS address;
CREATE OR REPLACE SQL SECURITY INVOKER VIEW address AS
  SELECT a.id AS id, 1 AS grp, a.ipaddress AS ip_addr, 32 AS mask, 0 AS port,
         a.account_id AS tag
  FROM switch.customer_sip_account a
  WHERE a.status = '1' AND a.ipauthfrom IN ('SRC','FROM')
    AND a.ipaddress IS NOT NULL AND a.ipaddress <> '';
SQL
ok "databases ready"

# ---------------------------------------------------------------- portal
step "deploying portal"
umask 022                     # reset the 077 from the secrets step: portal files must be group/other-readable
mkdir -p "$APP_DIR"
cp -a "$REPO/portal/." "$APP_DIR/"
cd "$APP_DIR"
mkdir -p "$APP_DIR"/storage/framework/{cache/data,sessions,views} "$APP_DIR"/storage/logs "$APP_DIR"/bootstrap/cache
# Write .env FIRST — composer's post-install 'artisan package:discover' boots the
# framework and needs a valid .env (APP_KEY etc.) or it exits non-zero.
cat > "$APP_DIR/.env" <<EOF
APP_NAME="DialerPortal DP Switch"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=https://${DOMAIN}
APP_LOCALE=en
LOG_CHANNEL=stack
LOG_LEVEL=warning
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=dpswitch_app
DB_USERNAME=dpswitch
DB_PASSWORD=${APP_DB_PASS}
SWITCH_DB_HOST=127.0.0.1
SWITCH_DB_PORT=3306
SWITCH_DB_DATABASE=switch
SWITCH_DB_USERNAME=dpswitch
SWITCH_DB_PASSWORD=${APP_DB_PASS}
SWITCHCDR_DB_DATABASE=switchcdr
SESSION_DRIVER=database
SESSION_ENCRYPT=true
SESSION_SECURE_COOKIE=true
SESSION_HTTP_ONLY=true
SESSION_SAME_SITE=strict
SESSION_LIFETIME=60
SESSION_EXPIRE_ON_CLOSE=true
CACHE_STORE=database
QUEUE_CONNECTION=database
FILESYSTEM_DISK=local
SWITCH_SHARED_SECRET=${SWITCH_SECRET}
SWITCH_SIP_DOMAIN=${DOMAIN}
SWITCH_SIP_PROXY=${PUBLIC_IP}
ADMIN_SEED_EMAIL=${ADMIN_EMAIL}
ADMIN_SEED_PASSWORD=${ADMIN_PASSWORD}
EOF
# own the tree as www-data BEFORE composer so vendor/ + generated caches are writable by it
chmod 640 "$APP_DIR/.env"
chown -R www-data:www-data "$APP_DIR"
find "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" -type d -exec chmod 775 {} \; 2>/dev/null || true
# Everything runs AS www-data so all generated files are owned/readable by php-fpm.
sudo -u www-data HOME=/tmp COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --prefer-dist -q \
    || die "composer install failed — see output above"
# db:seed must NOT be swallowed — a silent failure = no admin account on a green banner.
sudo -u www-data HOME=/tmp php8.3 artisan db:seed --class=AdminUserSeeder --force || die "admin seed failed — check DB grants / users table"
sudo -u www-data HOME=/tmp php8.3 artisan config:cache -q
# The 'auth' log only appears once something authenticates, but fail2ban resolves its
# logpath at startup and aborts the WHOLE jail set with "Have not found any log file
# for dpswitch-auth jail" if it is missing — which silently left every portal/SIP jail
# unloaded while the install still reported success. Seed it. Never truncate it on a
# re-run: that would erase the very evidence the jails ban on.
[ -f "$APP_DIR/storage/logs/auth.log" ] \
    || install -o www-data -g www-data -m 0640 /dev/null "$APP_DIR/storage/logs/auth.log"
ok "portal deployed"

# ---------------------------------------------------------------- server configs
step "installing server configs"
# freeswitch user (package usually creates it; ensure it exists to avoid chown failures)
id freeswitch >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin freeswitch || true
copy_render() { install -D -m "${3:-0644}" /dev/null "$2"; render < "$1" > "$2"; }
while IFS= read -r -d '' f; do
    rel="${f#"$REPO"/server}"; dest="$rel"
    case "$rel" in
        /etc/nftables.conf) continue;;                    # handled below (open-sip toggle)
        /usr/local/sbin/*) copy_render "$f" "$dest" 0755;;
        *) copy_render "$f" "$dest";;
    esac
done < <(find "$REPO/server" -type f -print0)

# --- nginx: enable our vhosts, drop Debian's stock default site (B1) ---
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/dpswitch.conf        /etc/nginx/sites-enabled/dpswitch.conf
ln -sf /etc/nginx/sites-available/dpswitch-switch.conf /etc/nginx/sites-enabled/dpswitch-switch.conf

# --- dashboard stats output dir (H4: dp-collect-stats mv target) ---
install -d -m 0755 /var/lib/dpswitch

# --- fs_cli credentials (root-only) ---
# event_socket.conf.xml is generated with a random ESL password, but dp-collect-stats
# (and any operator) calls plain `fs_cli -x ...` with no -p. Without this file every
# such call fails auth and the collector silently reports 0 calls / 0 channels
# forever, so the dashboard's live-call panel is permanently empty.
install -D -m 0600 /dev/null /etc/fs_cli.conf
cat > /etc/fs_cli.conf <<EOF
[default]
host     => 127.0.0.1
port     => 8021
password => ${ESL_PASSWORD}
EOF

# --- FreeSWITCH profile/dialplan hygiene ---
# Drop the IPv6 profiles (they bind [::]:5060/[::]:5080 -> collide with Kamailio /
# expose a second edge). KEEP external.xml: FreeSWITCH needs it to bridge OUT to
# carriers (sofia/external/...), and inbound 5080 is firewalled (H2, corrected).
rm -f /etc/freeswitch/sip_profiles/internal-ipv6.xml /etc/freeswitch/sip_profiles/external-ipv6.xml
# Remove vanilla sample dialplans so a portal/xml_curl outage cannot fall through
# to echo/voicemail/conference; our safe default.xml (shipped above) stays (M1).
rm -rf /etc/freeswitch/dialplan/default /etc/freeswitch/dialplan/public /etc/freeswitch/dialplan/skinny-patterns
# Vanilla FreeSWITCH ships a demo user directory (1000-1019, all sharing
# $${default_password}) and a sample carrier gateway pointing at example.com. The
# SBC never uses either — Kamailio authenticates at the edge against
# switch.customer_sip_account, and the internal profile is loopback-only with
# auth-calls=false — but leaving 20 accounts whose password is "1234" on a box
# that terminates PSTN calls is one config slip away from toll fraud. Delete them,
# and leave no usable default_password behind for anything that reads vars.xml.
rm -rf /etc/freeswitch/directory/default /etc/freeswitch/directory/default.xml
rm -rf /etc/freeswitch/sip_profiles/external /etc/freeswitch/sip_profiles/external-ipv6
# Set our codec list in the vanilla vars.xml (B3-codec) and neutralise the demo password.
if [ -f /etc/freeswitch/vars.xml ]; then
    sed -i -E 's|(global_codec_prefs=)[^"]*|\1PCMU,PCMA,OPUS,G722,G729,GSM|; s|(outbound_codec_prefs=)[^"]*|\1PCMU,PCMA,OPUS,G722,G729,GSM|' /etc/freeswitch/vars.xml
    sed -i -E "s|(default_password=)[^\"]*|\1$(gen 16)|" /etc/freeswitch/vars.xml
fi
chown -R freeswitch:freeswitch /etc/freeswitch 2>/dev/null || true

# nftables: render + inject public-SIP block on opt-in
PUBLIC_BLOCK="        # (public SIP not enabled — add carrier/admin IPs to the nft sets, or re-run with --open-sip)"
if [ "$OPEN_SIP" = yes ]; then
PUBLIC_BLOCK=$(cat <<'NFT'
        udp dport 5060 meter cc_sip_udp4 { ip saddr limit rate over 40/second burst 80 packets } drop
        udp dport 5060 accept comment "public SIP udp"
        tcp dport { 5060, 5061 } ct state new meter cc_sip_newc4 { ip saddr limit rate over 10/second burst 20 packets } drop
        tcp dport { 5060, 5061 } ct state new meter cc_sip_cnt4 { ip saddr ct count over 40 } drop
        tcp dport 5060 accept comment "public SIP tcp"
        tcp dport 5061 accept comment "public SIP tls"
        udp dport 16384-32768 accept comment "RTP media - public"
NFT
)
fi
render < "$REPO/server/etc/nftables.conf" | awk -v b="$PUBLIC_BLOCK" '{gsub(/# __PUBLIC_SIP_RULES__/, b)}1' > /etc/nftables.conf
sysctl --system >/dev/null 2>&1 || true
nft -f /etc/nftables.conf || warn "nftables load reported an error — review /etc/nftables.conf"
ok "configs installed"

# ---------------------------------------------------------------- TLS
# Certs live at a STABLE path (/etc/ssl/dpswitch) that nginx + kamailio read.
# Deliberately NOT /etc/letsencrypt/live/$DOMAIN: a self-signed placeholder there
# makes certbot refuse to issue ("live directory exists for ..."). So we place a
# placeholder in our own dir, start nginx, let certbot issue into ITS dir, then
# copy the real cert out to the stable path.
step "preparing TLS for $DOMAIN"
mkdir -p /var/www/html /etc/ssl/dpswitch /etc/kamailio/tls
LIVE="/etc/letsencrypt/live/$DOMAIN"
put_certs() {   # publish fullchain, privkey, chain to the stable paths nginx+kamailio use
    cp "$1" /etc/ssl/dpswitch/fullchain.pem; cp "$2" /etc/ssl/dpswitch/privkey.pem; cp "${3:-$1}" /etc/ssl/dpswitch/chain.pem
    cp "$1" /etc/kamailio/tls/fullchain.pem; cp "$2" /etc/kamailio/tls/privkey.pem
    chmod 0644 /etc/ssl/dpswitch/fullchain.pem /etc/ssl/dpswitch/chain.pem; chmod 0640 /etc/ssl/dpswitch/privkey.pem /etc/kamailio/tls/privkey.pem
    chown -R kamailio:kamailio /etc/kamailio/tls 2>/dev/null || true
}
# self-signed placeholder (our dir, never certbot's) so nginx can start
if [ ! -s /etc/ssl/dpswitch/fullchain.pem ]; then
    tmpk="$(mktemp)"; tmpc="$(mktemp)"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 -keyout "$tmpk" -out "$tmpc" -subj "/CN=$DOMAIN" >/dev/null 2>&1
    put_certs "$tmpc" "$tmpk" "$tmpc"; rm -f "$tmpk" "$tmpc"
fi
nginx -t && { systemctl enable nginx >/dev/null 2>&1 || true; systemctl restart nginx; } || warn "nginx config test failed — review 'nginx -t'"
# issue a real cert unless one already exists (renewal conf = certbot-managed lineage)
if [ ! -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]; then
    # Resolve via the system resolver but SKIP the Debian /etc/hosts line that maps
    # the FQDN to 127.0.1.1 (that entry would falsely look like a DNS mismatch).
    RES="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '$1!="127.0.1.1"{print $1; exit}')"
    [ -z "$RES" ] || [ "$RES" = "$PUBLIC_IP" ] || warn "heads-up: $DOMAIN resolves to '$RES', not $PUBLIC_IP — if issuance fails it's DNS; re-run in a few minutes."
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --email "$LE_EMAIL" --agree-tos --non-interactive \
        || warn "certbot could not issue yet (see output above); keeping the self-signed cert for now."
fi
# publish whatever certbot produced (this run or a prior one) to the stable paths
if [ -s "$LIVE/fullchain.pem" ]; then
    put_certs "$LIVE/fullchain.pem" "$LIVE/privkey.pem" "$LIVE/chain.pem"
    systemctl reload nginx 2>/dev/null || true; systemctl restart kamailio 2>/dev/null || true
    ok "TLS cert in place (Let's Encrypt)"
else
    ok "TLS using self-signed placeholder — re-run once DNS resolves for a real cert"
fi
# renewal deploy hook: republish to the stable paths + reload
install -D -m 0755 /dev/null /etc/letsencrypt/renewal-hooks/deploy/20-cc-reload.sh
cat > /etc/letsencrypt/renewal-hooks/deploy/20-cc-reload.sh <<EOF
#!/bin/sh
cp "$LIVE/fullchain.pem" /etc/ssl/dpswitch/fullchain.pem
cp "$LIVE/privkey.pem"   /etc/ssl/dpswitch/privkey.pem
cp "$LIVE/chain.pem"     /etc/ssl/dpswitch/chain.pem 2>/dev/null || cp "$LIVE/fullchain.pem" /etc/ssl/dpswitch/chain.pem
cp "$LIVE/fullchain.pem" /etc/kamailio/tls/fullchain.pem
cp "$LIVE/privkey.pem"   /etc/kamailio/tls/privkey.pem
chown -R kamailio:kamailio /etc/kamailio/tls 2>/dev/null || true
systemctl reload nginx; systemctl restart kamailio
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/20-cc-reload.sh

# ---------------------------------------------------------------- services
step "enabling services"
systemctl daemon-reload    # pick up the timer/service units the copy loop just installed
systemctl enable php8.3-fpm nginx nftables fail2ban >/dev/null 2>&1 || true
# The freeswitch package's own postinst starts the unit before its user exists, so the
# unit is already in a failed state ("start request repeated too quickly") by the time
# we get here; systemd then refuses further starts until the failure is cleared.
systemctl reset-failed kamailio freeswitch fail2ban >/dev/null 2>&1 || true
# RESTART, not `enable --now`: on a re-run these units are already active, so --now is a
# no-op and the daemon keeps serving its old config. That is how a fail2ban whose jails
# had failed to load stayed stuck with only the distro sshd jail even after the config
# on disk had been fixed — it never re-read it.
systemctl restart php8.3-fpm >/dev/null 2>&1 || warn "php8.3-fpm did not restart — check: journalctl -u php8.3-fpm"
systemctl restart fail2ban  >/dev/null 2>&1 || warn "fail2ban did not restart — check: journalctl -u fail2ban"
for svc in kamailio freeswitch; do systemctl enable "$svc" >/dev/null 2>&1 || true; systemctl restart "$svc" >/dev/null 2>&1 || warn "$svc did not start — check: journalctl -u $svc"; done
for t in dpswitch-scheduler.timer dp-stats.timer; do systemctl enable --now "$t" >/dev/null 2>&1 || warn "$t did not enable — check: systemctl status $t"; done
systemctl reload nginx 2>/dev/null || systemctl restart nginx || true

# ---------------------------------------------------------------- verify
# Everything above can "succeed" while leaving the box non-operational: a jail whose
# logpath glob is empty is skipped, a SIP daemon can die right after restart. Check the
# things that actually matter and say so out loud, rather than printing a green banner.
step "verifying"
FAILED=0
for svc in nginx php8.3-fpm mariadb kamailio freeswitch fail2ban nftables; do
    systemctl is-active --quiet "$svc" || { warn "$svc is NOT running — journalctl -u $svc"; FAILED=1; }
done
# fail2ban silently drops jails it cannot read a log for; -t surfaces the real reason.
if ! fail2ban-client -t >/dev/null 2>&1; then
    warn "fail2ban config test failed — jails may not be active. Detail:"
    fail2ban-client -t 2>&1 | grep -iE "error|warn" | tail -5
    FAILED=1
fi
for jail in dpswitch-auth dpswitch-probe dpsip-auth dpsip-scanner; do
    fail2ban-client status "$jail" >/dev/null 2>&1 || { warn "fail2ban jail '$jail' is not loaded"; FAILED=1; }
done
# Kamailio must own the public SIP edge, FreeSWITCH must answer on the ESL loopback.
ss -lnu 2>/dev/null | grep -q ":5060 " || { warn "nothing is listening on udp/5060 — Kamailio did not bind the SIP edge"; FAILED=1; }
ss -lnt 2>/dev/null | grep -q "127.0.0.1:8021" || { warn "FreeSWITCH ESL is not listening on 127.0.0.1:8021"; FAILED=1; }
# The dialplan endpoint is the whole call path: no XML here means no call ever routes.
DP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080/switch/dialplan \
    -H "X-Switch-Secret: ${SWITCH_SECRET}" -d 'Caller-Destination-Number=10000000000' 2>/dev/null || echo 000)"
[ "$DP_CODE" = 200 ] || { warn "switch dialplan endpoint returned HTTP $DP_CODE (expected 200) — FreeSWITCH cannot route calls"; FAILED=1; }
[ "$FAILED" = 0 ] && ok "all services, jails, and the switch API verified" || warn "install finished with the problems above — fix them before taking traffic"

# ---------------------------------------------------------------- done
echo; c "1;32" "============================================================"
c "1;32" " DialerPortal DP Switch installed."
c "1;32" "============================================================"
echo "  Portal:        https://$DOMAIN"
echo "  Admin login:   $ADMIN_EMAIL"
echo "  Admin pass:    $ADMIN_PASSWORD"
echo "  Secrets file:  $CRED_DIR/install-credentials  (root-only)"
echo "  SIP public:    $OPEN_SIP"
echo
echo "  Next:"
echo "   1. Point DNS: $DOMAIN -> $PUBLIC_IP  (then: certbot certonly ... if self-signed)"
echo "   2. Add a carrier IP:  nft add element inet filter carrier_v4 { <carrier-ip> }"
echo "   3. Add your admin IP: nft add element inet filter admin_v4 { <your-ip> }"
[ "$OPEN_SIP" = yes ] && echo "   4. SIP is OPEN to the world (rate-limited). Register a phone: user@$DOMAIN via proxy $PUBLIC_IP."
echo "   Log in and change the admin password immediately."
echo
