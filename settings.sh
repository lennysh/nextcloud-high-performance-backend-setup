# shellcheck shell=bash
# settings.sh — optional configuration for: ./setup-nextcloud-hpb.sh settings.sh
#
# This file is sourced by the main script (same shell). Use only NAME=value and
# comments: no "export" or commands required.
#
# Interactive vs unattended
# -------------------------
# • UNATTENDED_INSTALL=false (default): a five-line whiptail checklist maps 1:1
#   to the SHOULD_INSTALL_* and BEHIND_* flags (saved above are reset, then
#   defaults for each line are taken from the values you set here so the TUI
#   matches this file; press OK to apply the checkmarks you see).
# • UNATTENDED_INSTALL=true: no checklist; the SHOULD_INSTALL_* variables below
#   must be set to describe the install. You must also set DRY_RUN, and every
#   value that show_dialogs() would otherwise ask for (see “Required for
#   unattended” below).
#
# Upstream reference (different OS / scope):
#   https://github.com/sunweaver/nextcloud-high-performance-backend-setup

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
# true = print actions only; no system changes.
DRY_RUN=false
# true = no whiptail; use this file for all choices (unattended / automation).
UNATTENDED_INSTALL=false

# ---------------------------------------------------------------------------
# Required for unattended (UNATTENDED_INSTALL=true)
# ---------------------------------------------------------------------------
# Comma-separated Nextcloud hostnames the HPB is allowed to talk to (no scheme).
#NEXTCLOUD_SERVER_FQDNS="nextcloud.example.org"
# This host’s public DNS name (HPB vhost and TLS); no https://
#SERVER_FQDN="talk-hpb.example.org"

# Log and temp paths (uncommented defaults; safe to adjust)
LOGFILE_PATH="$(pwd)/setup-nextcloud-hpb-$(date +%Y-%m-%dT%H:%M:%SZ).log"
TMP_DIR_PATH="./tmp"
# Where generated secrets are written; parent dirs are created. Required if unset
# in unattended mode (otherwise set interactively).
#SECRETS_FILE_PATH="./nextcloud-hpb.secrets"
# When SHOULD_INSTALL_CERTBOT is true, Let’s Encrypt / ACME account contact
# (expiry and policy notices; not for SMTP in this fork).
#EMAIL_USER_ADDRESS="admin@example.com"

# ---------------------------------------------------------------------------
# What to install (used when UNATTENDED_INSTALL=true, or as defaults the script
# may merge; use unattended to rely on them fully)
# ---------------------------------------------------------------------------
# Talk stack: build nextcloud-spreed-signaling, NATS, Janus RPM, certificates data.
SHOULD_INSTALL_SIGNALING=true
# open HTTP/HTTPS (and related) in firewalld when nginx is used; also needed for
# the Talk stack in this script.
SHOULD_INSTALL_FIREWALLD=true
# Local TURN/STUN. If false, set STUN/TURN in Nextcloud → Administration → Talk.
SHOULD_INSTALL_COTURN=false
# On-host TLS proxy for SERVER_FQDN; config under /etc/nginx/conf.d/
SHOULD_INSTALL_NGINX=true
# Certbot (nginx plugin) for Let’s Encrypt. Requires valid DNS for SERVER_FQDN.
SHOULD_INSTALL_CERTBOT=true
# true = do not install nginx or Certbot here; terminate TLS on Traefik, Caddy,
# etc. After a successful run, see tmp/reverse-proxy/ for a Traefik example.
BEHIND_EXISTING_REVERSE_PROXY=false
# [http] listen for nextcloud-spreed-signaling — must be host:port (not bare IP).
# Default 127.0.0.1:8080 when Traefik/nginx is on this host.
# Use 0.0.0.0:8080 only if a remote reverse proxy must reach this host; restrict
# port 8080 with firewalld or network ACLs to the proxy IP.
#SIGNALING_HTTP_LISTEN="127.0.0.1:8080"
#SIGNALING_HTTP_LISTEN="0.0.0.0:8080"

# ---------------------------------------------------------------------------
# Optional TLS / key paths (empty = defaults under /etc/letsencrypt/live/…
# from Certbot; override if you manage certs yourself)
# ---------------------------------------------------------------------------
#DHPARAM_PATH="/etc/certs/dhp/dhp.pem"
#SSL_CERT_PATH_RSA="/etc/letsencrypt/live/.../fullchain.pem"
#SSL_CERT_KEY_PATH_RSA=""
#SSL_CHAIN_PATH_RSA=""
#SSL_CERT_PATH_ECDSA=""
#SSL_CERT_KEY_PATH_ECDSA=""
#SSL_CHAIN_PATH_ECDSA=""

# ---------------------------------------------------------------------------
# Nginx (SSL stapling / OCSP resolver in generated config)
# ---------------------------------------------------------------------------
# Empty = 9.9.9.9 in the template.
DNS_RESOLVER=""

# ---------------------------------------------------------------------------
# Optional: public IP discovery (signaling and firewall hints)
# ---------------------------------------------------------------------------
#EXTERNAL_IP_PRIMARY_ENDPOINT="https://ident.me"
#EXTERNAL_IP_FALLBACK_ENDPOINT="https://tnedi.me"
# Usually leave unset; the script fills them. Override only in special network cases.
#EXTERNAL_IPV4=""
#EXTERNAL_IPV6=""

# ---------------------------------------------------------------------------
# Hardening
# ---------------------------------------------------------------------------
# true = disable sshd after install (ensure console or other access first).
#DISABLE_SSH_SERVER=false
