# Enterprise Linux fork — Nextcloud Talk high-performance backend.
# Run as root: ./setup-nextcloud-hpb.sh settings.sh
# Upstream reference (different OS / scope): https://github.com/sunweaver/nextcloud-high-performance-backend-setup

DRY_RUN=false
UNATTENDED_INSTALL=false

#NEXTCLOUD_SERVER_FQDNS="nextcloud.example.org"
#SERVER_FQDN="talk-hpb.example.org"

# Talk HPB (Janus, NATS, nextcloud-spreed-signaling from source; Janus+coturn from repos)
SHOULD_INSTALL_SIGNALING=true
# Optional local TURN/STUN (coturn). If false, configure STUN/TURN in Talk admin.
SHOULD_INSTALL_COTURN=false

SHOULD_INSTALL_FIREWALLD=true
SHOULD_INSTALL_NGINX=true
SHOULD_INSTALL_CERTBOT=true
# Set true to terminate TLS elsewhere (Traefik, Caddy, etc.): nginx & Certbot are skipped; see tmp/reverse-proxy/ after run.
#BEHIND_EXISTING_REVERSE_PROXY=false
# Host:port for nextcloud-spreed-signaling HTTP (default 127.0.0.1:8080). Use 0.0.0.0:8080 if a remote proxy must connect.
#SIGNALING_HTTP_LISTEN="127.0.0.1:8080"

LOGFILE_PATH="$(pwd)/setup-nextcloud-hpb-$(date +%Y-%m-%dT%H:%M:%SZ).log"
TMP_DIR_PATH="./tmp"
#SECRETS_FILE_PATH=""

# Email for Let's Encrypt / Certbot account notices only
EMAIL_USER_ADDRESS=""

#DISABLE_SSH_SERVER=false
DNS_RESOLVER=""
