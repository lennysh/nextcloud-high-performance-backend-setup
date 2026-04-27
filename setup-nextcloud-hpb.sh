#!/bin/bash

set -eo pipefail

# Sane defaults (Don't override these settings here!)
# Can be overridden by specifying a settings file as first parameter.
# See settings.sh
DRY_RUN=false
UNATTENDED_INSTALL=false
NEXTCLOUD_SERVER_FQDNS=""  # Ask user
SERVER_FQDN=""             # Ask user
SSL_CERT_PATH_RSA=""       # Will be auto filled, if not overriden by settings file.
SSL_CERT_KEY_PATH_RSA=""   # Will be auto filled, if not overriden by settings file.
SSL_CHAIN_PATH_RSA=""      # Will be auto filled, if not overriden by settings file.
SSL_CERT_PATH_ECDSA=""     # Will be auto filled, if not overriden by settings file.
SSL_CERT_KEY_PATH_ECDSA="" # Will be auto filled, if not overriden by settings file.
SSL_CHAIN_PATH_ECDSA=""    # Will be auto filled, if not overriden by settings file.
DHPARAM_PATH=""            # Will be auto filled, if not overriden by settings file.
LOGFILE_PATH="setup-nextcloud-hpb-$(date +%Y-%m-%dT%H:%M:%SZ).log"
TMP_DIR_PATH="./tmp"
SECRETS_FILE_PATH=""   # Ask user
EMAIL_USER_ADDRESS=""  # Certbot / ACME account contact when Certbot is enabled
DISABLE_SSH_SERVER=false
# RHEL-family major version (filled from /etc/os-release)
EL_OS_VERSION_MAJOR=""
SHOULD_INSTALL_COTURN=false
SHOULD_INSTALL_FIREWALLD=false
# When true, skip nginx and Certbot; use Traefik/Caddy/etc. for TLS and routing (see data/reverse-proxy/).
BEHIND_EXISTING_REVERSE_PROXY=false
# Signaling [http] listen (host:port). Default 127.0.0.1:8080. Use 0.0.0.0:8080 only if a remote proxy must reach this host (lock down in firewall).
SIGNALING_HTTP_LISTEN=""

# External IP lookup endpoints (can be overridden via settings file)
EXTERNAL_IP_PRIMARY_ENDPOINT="https://ident.me"
EXTERNAL_IP_FALLBACK_ENDPOINT="https://tnedi.me"
EXTERNAL_IPV4=""
EXTERNAL_IPV6=""

SETUP_VERSION=$(cat VERSION | head -n 1 | tr '\n' ' ')

function show_dialogs() {
	if [ "$LOGFILE_PATH" = "" ]; then
		if [ "$UNATTENDED_INSTALL" = true ]; then
			log_err "Can't continue since this is a non-interactive installation and I'm" \
			        "missing LOGFILE_PATH!"
			exit 1
		fi

		LOGFILE_PATH=$(
			whiptail --title "Logfile path" \
				--inputbox "Please enter a path to which this script can write $(
				)a log file.\n\nThe log directory and its parent directories will get $(
				)created automatically if they don't yet exist." 10 65 \
				"setup-nextcloud-hpb-$(date +%Y-%m-%dT%H:%M:%SZ).log" \
				3>&1 1>&2 2>&3
		)
	fi
	log "Using '$LOGFILE_PATH' for LOGFILE_PATH"

	if [ "$DRY_RUN" = "" ]; then
		if [ "$UNATTENDED_INSTALL" = true ]; then
			log_err "Can't continue since this is a non-interactive installation and I'm missing DRY_RUN!"
			exit 1
		fi

		if whiptail --title "Dry-Run Mode" --yesno "Do you want to run in dry $(
		)mode? This will ensure that no serious changes will get applied to your $(
		)system." 10 65 --defaultno; then
			DRY_RUN=true
		else
			DRY_RUN=true
		fi
	fi
	log "Using '$DRY_RUN' for DRY_RUN."

	if [ "$NEXTCLOUD_SERVER_FQDNS" = "" ]; then
		if [ "$UNATTENDED_INSTALL" = true ]; then
			log_err "Can't continue since this is a non-interactive installation and I'm" \
			        "missing NEXTCLOUD_SERVER_FQDNS!"
			exit 1
		fi

		NEXTCLOUD_SERVER_FQDNS=$(
			whiptail --title "Nextcloud Server Domain" \
				--inputbox "Please enter your Nextcloud server's domain name here. $(
				)(Omit http(s)://, just put in the plain domain name!).\n\n$(
				)You can also specify multiple Nextcloud servers by separating $(
				)them using a comma." 12 65 \
				"nextcloud.example.org" 3>&1 1>&2 2>&3
		)
	fi
	# Filter out HTTPS:// or HTTP://
	NEXTCLOUD_SERVER_FQDNS=$(echo $NEXTCLOUD_SERVER_FQDNS | sed -r "s#https?\:\/\/##gi")
	log "Using '$NEXTCLOUD_SERVER_FQDNS' for NEXTCLOUD_SERVER_FQDNS."

	if [ "$SERVER_FQDN" = "" ]; then
		if [ "$UNATTENDED_INSTALL" = true ]; then
			log_err "Can't continue since this is a non-interactive installation and I'm" \
			        "missing SERVER_FQDN!"
			exit 1
		fi

		SERVER_FQDN=$(
			whiptail --title "High-Performance Backend Server Domain" \
				--inputbox "Please enter your high performance backend $(
				)server's domain name here. (Omit http(s)://!).\n\n$(
				)Also please note that this domain should already exist in DNS $(
				)or else SSL certificate creation will fail!" \
				12 65 "nc-workhorse.example.org" 3>&1 1>&2 2>&3
		)
	fi
	# Filter out HTTPS:// or HTTP://
	SERVER_FQDN=$(echo $SERVER_FQDN | sed -r "s#https?\:\/\/##gi")
	log "Using '$SERVER_FQDN' for SERVER_FQDN."

	# - SSL Cert stuff below -
	if [ "$DHPARAM_PATH" = "" ]; then
		DHPARAM_PATH="/etc/certs/dhp/dhp.pem"
		log "Using default path '$DHPARAM_PATH' for DHPARAM_PATH."
	else
		log "Using '$DHPARAM_PATH' for DHPARAM_PATH."
	fi

	if [ "$SSL_CERT_PATH_RSA" = "" ]; then
		SSL_CERT_PATH_RSA="/etc/letsencrypt/live/$SERVER_FQDN-rsa/fullchain.pem"
		log "Using default path '$SSL_CERT_PATH_RSA' for SSL_CERT_PATH_RSA."
	else
		log "Using '$SSL_CERT_PATH_RSA' for SSL_CERT_PATH_RSA."
	fi

	if [ "$SSL_CERT_PATH_ECDSA" = "" ]; then
		SSL_CERT_PATH_ECDSA="/etc/letsencrypt/live/$SERVER_FQDN-ecdsa/fullchain.pem"
		log "Using default path '$SSL_CERT_PATH_ECDSA' for SSL_CERT_PATH_ECDSA."
	else
		log "Using '$SSL_CERT_PATH_ECDSA' for SSL_CERT_PATH_ECDSA."
	fi

	if [ "$SSL_CERT_KEY_PATH_RSA" = "" ]; then
		SSL_CERT_KEY_PATH_RSA="/etc/letsencrypt/live/$SERVER_FQDN-rsa/privkey.pem"
		log "Using default path '$SSL_CERT_KEY_PATH_RSA' for SSL_CERT_KEY_PATH_RSA."
	else
		log "Using '$SSL_CERT_KEY_PATH_RSA' for SSL_CERT_KEY_PATH_RSA."
	fi

	if [ "$SSL_CERT_KEY_PATH_ECDSA" = "" ]; then
		SSL_CERT_KEY_PATH_ECDSA="/etc/letsencrypt/live/$SERVER_FQDN-ecdsa/privkey.pem"
		log "Using default path '$SSL_CERT_KEY_PATH_ECDSA' for SSL_CERT_KEY_PATH_ECDSA."
	else
		log "Using '$SSL_CERT_KEY_PATH_ECDSA' for SSL_CERT_KEY_PATH_ECDSA."
	fi
	# -----

	if [ "$SSL_CHAIN_PATH_RSA" = "" ]; then
		SSL_CHAIN_PATH_RSA="/etc/letsencrypt/live/$SERVER_FQDN-rsa/chain.pem"
		log "Using default path '$SSL_CHAIN_PATH_RSA' for SSL_CHAIN_PATH_RSA."
	else
		log "Using '$SSL_CHAIN_PATH_RSA' for SSL_CHAIN_PATH_RSA."
	fi

	if [ "$SSL_CHAIN_PATH_ECDSA" = "" ]; then
		SSL_CHAIN_PATH_ECDSA="/etc/letsencrypt/live/$SERVER_FQDN-ecdsa/chain.pem"
		log "Using default path '$SSL_CHAIN_PATH_ECDSA' for SSL_CHAIN_PATH_ECDSA."
	else
		log "Using '$SSL_CHAIN_PATH_ECDSA' for SSL_CHAIN_PATH_ECDSA."
	fi

	if [ "$TMP_DIR_PATH" = "" ]; then
		if [ "$UNATTENDED_INSTALL" = true ]; then
			log_err "Can't continue since this is a non-interactive installation and I'm" \
			        "missing TMP_DIR_PATH!"
			exit 1
		fi

		TMP_DIR_PATH=$(
			whiptail --title "Temporary directory for configuration" \
				--inputbox "Please enter a directory path in which this "$(
				)"script can put temporary configuration files.\n\n"$(
				)"The directory and its parents will get created automatically." \
				10 65 "./tmp" 3>&1 1>&2 2>&3
		)
	fi
	log "Using '$TMP_DIR_PATH' for TMP_DIR_PATH."

	if [ "$SECRETS_FILE_PATH" = "" ]; then
		if [ "$UNATTENDED_INSTALL" = true ]; then
			log_err "Can't continue since this is a non-interactive installation and I'm" \
			        "missing SECRETS_FILE_PATH!"
			exit 1
		fi

		SECRETS_FILE_PATH=$(
			whiptail --title "Secrets, passwords and configuration file" \
				--inputbox "Please enter a path to a file where all "$(
				)"secrets, passwords and configuration shall be stored.\n\n"$(
				)"The directory and its parents get created automatically." \
				10 65 "./nextcloud-hpb.secrets" 3>&1 1>&2 2>&3
		)
	fi
	log "Using '$SECRETS_FILE_PATH' for SECRETS_FILE_PATH."

	# Let's Encrypt / ACME account contact (Certbot only; not used elsewhere in this Talk-only fork)
	if [ "$SHOULD_INSTALL_CERTBOT" = true ]; then
		if [ "$EMAIL_USER_ADDRESS" = "" ]; then
			if [ "$UNATTENDED_INSTALL" = true ]; then
				log_err "Can't continue: Certbot is enabled but EMAIL_USER_ADDRESS is empty $(
				)(set it in settings.sh to your address for Let's Encrypt notices)."
				exit 1
			fi

			EMAIL_USER_ADDRESS=$(
				whiptail --title "Let's Encrypt contact email" \
					--inputbox "Enter an email address for your Let's Encrypt / ACME account.$(
					)\nUsed for certificate expiry and account notices only." \
					11 65 "johndoe@example.com" 3>&1 1>&2 2>&3
			)
		fi
		log "Using '$EMAIL_USER_ADDRESS' for Certbot (ACME contact)."
	fi

	CERTBOT_AGREE_TOS=""
	LETSENCRYPT_TOS_URL="https://community.letsencrypt.org/tos"
	if [ "$SHOULD_INSTALL_CERTBOT" = true ]; then
		if [ "$UNATTENDED_INSTALL" != true ]; then
			if whiptail --title "Letsencrypt - Terms of Service" \
				--yesno "Do you want to silently accept Letsencrypt's Terms of $(
				)Service here? If you select 'no' here, the Terms of Service $(
				)will be displayed during SSL certificate retrieval during the $(
				)installation process.\n\nYou can always read Letsencrypt's $(
				)Terms of Service here:\n$LETSENCRYPT_TOS_URL" \
				13 75 3>&1 1>&2 2>&3; then
				CERTBOT_AGREE_TOS="--agree-tos"
			fi
		fi
	fi
	log "Using '$CERTBOT_AGREE_TOS' for CERTBOT_AGREE_TOS."

	if [ "$DISABLE_SSH_SERVER" != true ]; then
		if [ "$UNATTENDED_INSTALL" != true ]; then
			if whiptail --title "Deactivate SSH server?" --defaultno \
				--yesno "Should the 'ssh' service be disabled?" \
				10 70 3>&1 1>&2 2>&3; then
				DISABLE_SSH_SERVER=true
			fi
		fi
	fi
	log "Using '$DISABLE_SSH_SERVER' for DISABLE_SSH_SERVER."

	SIGNALING_BUILD_FROM_SOURCES="true"
	log "Using '$SIGNALING_BUILD_FROM_SOURCES' for SIGNALING_BUILD_FROM_SOURCES."
}

# SUPPORT FOR COLORS! (If terminal supports it)
# Check if stdout is a terminal and set colors if available.
if test -t 1; then
	# Pause set -e
	set +e
	# See if it supports colors...
	ncolors=$(tput colors 2> /dev/null)
	set -e

	if [[ -n "$ncolors" && "$ncolors" -ge 8 ]]; then
		bold="$(tput bold)"
		underline="$(tput smul)"
		standout="$(tput smso)"
		normal="$(tput sgr0)"
		black="$(tput setaf 0)"
		red="$(tput setaf 1)"
		green="$(tput setaf 2)"
		yellow="$(tput setaf 3)"
		blue="$(tput setaf 4)"
		magenta="$(tput setaf 5)"
		cyan="$(tput setaf 6)"
		white="$(tput setaf 7)"
	fi
fi

# Trap to reset terminal colors on exit
trap 'printf "%s" "$normal"' EXIT INT TERM HUP

function log() {
	# Strip ANSI color codes before writing to log file
	echo -e "$@" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" >> "$LOGFILE_PATH" 2>/dev/null || true
	echo -e "${blue}$@${normal}"
}

function log_err() {
	echo -e "$@" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" >> "$LOGFILE_PATH" 2>/dev/null || true
	echo -e "${red}✗ Error: $@${normal}" >&2
}

function generate_dhparam_file() {
	if [ "$BUILT_DHPARAM_FILE" == "true" ]; then
		# Skip if we already generated dhparam file.
		return 0
	fi

	if [ -s "$DHPARAM_PATH" ]; then
		# Rebuilding dhparam file.
		log "Removing old dhparam file at '$DHPARAM_PATH'."
		rm -fv "$DHPARAM_PATH" 2>&1 | tee -a "$LOGFILE_PATH"
	fi

	log "Generating new dhparam file…"
	is_dry_run || mkdir -p "$(dirname $DHPARAM_PATH)"
	is_dry_run || touch "$DHPARAM_PATH"
	is_dry_run || openssl dhparam -dsaparam -out "$DHPARAM_PATH" 4096
	is_dry_run || chmod 644 "$DHPARAM_PATH"

	BUILT_DHPARAM_FILE="true"
}

# Deploys target_file_path to source_file_path while respecting
# potential custom user config.
# param 1: source_file_path
# param 2: target_file_path
# returns: 1 if already deployed and 0 if not.
function deploy_file() {
	source_file_path="$1"
	target_file_path="$2"
	log "Deploying $target_file_path"
	if [[ -s "$target_file_path" ]]; then
		checksum_deployed=$(sha256sum "$target_file_path" | cut -d " " -f1)
		checksum_expected=$(sha256sum "$source_file_path" | cut -d " " -f1)
		if [ "${checksum_deployed}" = "${checksum_expected}" ]; then
			log "$target_file_path was already deployed."
			return 1
		else
			if [ "$UNATTENDED_INSTALL" = true ]; then
				is_dry_run "Would've replaced existing '$target_file_path'." || \
					cp "$source_file_path" "$target_file_path"
			else
				log "file '$target_file_path' exists and will be updated deployed."
				is_dry_run "Would've replaced existing '$target_file_path'." || \
					cp "$source_file_path" "$target_file_path"
			fi
		fi
	else
		# Target file is empty or doesn't exist.
		is_dry_run "Would've deployed '$target_file_path'." || cp "$source_file_path" "$target_file_path"
	fi
	return 0
}

function check_root_perm() {
	if [[ $(id -u) -ne 0 ]]; then
		log_err "Please run the this (setup-nextcloud-hpb) script as root."
		exit 1
	fi
}

function check_enterprise_linux() {
	if ! [ -s /etc/os-release ]; then
		log_err "Couldn't read /etc/os-release!"
		exit 1
	fi
	# shellcheck source=/dev/null
	source /etc/os-release
	local id_lc="${ID,,}"
	case "$id_lc" in
	rhel | rocky | almalinux | centos | ol | fedora) ;;
	*)
		log_err "This script targets Fedora and Enterprise Linux (RHEL, Rocky, AlmaLinux, Oracle Linux, CentOS Stream). Detected ID='$ID'."
		exit 1
		;;
	esac
	EL_OS_VERSION_MAJOR="${VERSION_ID%%.*}"
	if ! [[ "$EL_OS_VERSION_MAJOR" =~ ^[0-9]+$ ]]; then
		EL_OS_VERSION_MAJOR="9"
	fi
	if [ "$id_lc" != "fedora" ] && [ "$EL_OS_VERSION_MAJOR" -lt 8 ]; then
		log_err "Enterprise Linux major version '$EL_OS_VERSION_MAJOR' is too old (need 8+)."
		exit 1
	fi
	log "Detected OS: $PRETTY_NAME (EL major for templates: $EL_OS_VERSION_MAJOR)."
}

# Executes command only if NOT in dry-run mode.
# Usage: is_dry_run "Description of what would happen" || actual_command
# If in dry-run mode: logs the description and returns success (allows || to skip command)
# If not in dry-run mode: returns failure (allows || to execute command)
function is_dry_run() {
	if [ "$DRY_RUN" == true ]; then
		if [[ -n "$1" ]]; then
			log "${yellow}$1${normal}"
		fi
		return 0
	else
		return 1
	fi
}

# Helper function to fetch external IP address with fallback mirrors
# Usage: fetch_external_ip_with_fallback 4  # for IPv4
#        fetch_external_ip_with_fallback 6  # for IPv6
# Returns: the public IP address (stdout)
# Exits with 1 if both endpoints fail
function fetch_external_ip_with_fallback() {
	local family="$1"
	local wget_flag="-4"
	local label="IPv4"
	local result=""
	local primary_endpoint="${EXTERNAL_IP_PRIMARY_ENDPOINT:-https://ident.me}"
	local fallback_endpoint="${EXTERNAL_IP_FALLBACK_ENDPOINT:-https://tnedi.me}"

	if [ "$family" = "6" ]; then
		wget_flag="-6"
		label="IPv6"
	fi

	result=$(wget "$wget_flag" "$primary_endpoint" -O - -o /dev/null 2>/dev/null | tr -d '[:space:]')

	if [ -n "$result" ]; then
		echo "$result"
		return 0
	fi

	log_err "[External IP] Failed to fetch $label from $primary_endpoint, trying fallback endpoint $fallback_endpoint…"
	result=$(wget "$wget_flag" "$fallback_endpoint" -O - -o /dev/null 2>/dev/null | tr -d '[:space:]')

	if [ -n "$result" ]; then
		echo "$result"
		return 0
	fi

	log_err "[External IP] ERROR: Failed to fetch $label from both $primary_endpoint and $fallback_endpoint."
	return 1
}

function announce_installation() {
	local software_name="$1"
	local box_width=$((${#software_name} + 4))

	# Top border
	echo -e "${green}┌$(printf '─%.0s' $(seq 1 $box_width))┐${normal}"
	# Content
	echo -e "${green}│  ${software_name}  │${normal}"
	# Bottom border
	echo -e "${green}└$(printf '─%.0s' $(seq 1 $box_width))┘${normal}"

	sleep 1
}

# Replaces a placeholder in one or more files with an arbitrary value
# Supports all characters except NUL bytes. Useful for passwords.
function replace_placeholder_in_files() {
    local placeholder="$1"
    local replacement="$2"

    shift 2

    PLACEHOLDER="$placeholder" REPLACEMENT="$replacement" \
        perl -0777 -i -pe '
            BEGIN {
                $placeholder = $ENV{PLACEHOLDER};
                $replacement = $ENV{REPLACEMENT};
            }
            s/\Q$placeholder\E/$replacement/g;
        ' -- "$@"
}

function main() {
	if [ -s "$LOGFILE_PATH" ]; then
		rm -v $LOGFILE_PATH |& tee -a $LOGFILE_PATH
	fi

	log "Starting script at: $(date)"
	log "Nextcloud HPB setup script version: $SETUP_VERSION"

	check_root_perm

	# Make sure PATH is correctly set.
	# There are VPS providers which alter the PATH env variable.
	export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

	check_enterprise_linux

	# Load Settings (hopefully vars above get overwritten!)
	SETTINGS_FILE="$1"
	if [ -s "$SETTINGS_FILE" ]; then
		log "Loading settings file '$SETTINGS_FILE'…"
		source "$SETTINGS_FILE"
	else
		log "No settings file specified using defaults or asking user for input."
	fi

	### INSTALL DEPENDENCIES
	# Check 'whiptail' dependency
	if ! command -v whiptail &>/dev/null; then
		log "whiptail could not be found! Trying to install it…"
		if ! is_dry_run; then
			if [ "$UNATTENDED_INSTALL" == true ]; then
				log "Trying unattended install for 'whiptail' (newt package)."
				args_dnf="-y -q"
			else
				args_dnf="-y"
			fi

			dnf install $args_dnf newt 2>&1 | tee -a $LOGFILE_PATH
		fi
	fi

	# Check 'wget' dependency
	if ! command -v wget &>/dev/null; then
		log "wget could not be found! Trying to install it…"
		if ! is_dry_run; then
			if [ "$UNATTENDED_INSTALL" == true ]; then
				log "Trying unattended install for 'wget'."
				args_dnf="-y -q"
			else
				args_dnf="-y"
			fi

			dnf install $args_dnf wget 2>&1 | tee -a $LOGFILE_PATH
		fi
	fi
	###

	# Let's check if we should open dialogs.
	if [ "$UNATTENDED_INSTALL" != true ]; then
		# Preserve settings.sh (reset below clears SHOULD_INSTALL_*).
		_CHECKLIST_PRESET_SIGNALING="${SHOULD_INSTALL_SIGNALING:-false}"
		_CHECKLIST_PRESET_FIREWALLD="${SHOULD_INSTALL_FIREWALLD:-false}"
		_CHECKLIST_PRESET_NGINX="${SHOULD_INSTALL_NGINX:-false}"
		_CHECKLIST_PRESET_CERTBOT="${SHOULD_INSTALL_CERTBOT:-false}"
		_CHECKLIST_PRESET_COTURN="${SHOULD_INSTALL_COTURN:-false}"
		SHOULD_INSTALL_FIREWALLD=false
		SHOULD_INSTALL_SIGNALING=false
		SHOULD_INSTALL_CERTBOT=false
		SHOULD_INSTALL_NGINX=false
		SHOULD_INSTALL_COTURN=false

		# Five rows map to the same flags as settings.sh / unattended mode.
		_DEFAULT_HPB=OFF
		_DEFAULT_FW=OFF
		_DEFAULT_WEB=OFF
		_DEFAULT_TURN=OFF
		_DEFAULT_PROXY=OFF
		if [ "$_CHECKLIST_PRESET_SIGNALING" = true ]; then
			_DEFAULT_HPB=ON
		fi
		if [ "$_CHECKLIST_PRESET_FIREWALLD" = true ]; then
			_DEFAULT_FW=ON
		fi
		if [ "$_CHECKLIST_PRESET_NGINX" = true ] && [ "$_CHECKLIST_PRESET_CERTBOT" = true ] \
			&& [ "$BEHIND_EXISTING_REVERSE_PROXY" != true ]; then
			_DEFAULT_WEB=ON
		fi
		if [ "$_CHECKLIST_PRESET_COTURN" = true ]; then
			_DEFAULT_TURN=ON
		fi
		if [ "$BEHIND_EXISTING_REVERSE_PROXY" = true ]; then
			_DEFAULT_HPB=ON
			_DEFAULT_WEB=OFF
			_DEFAULT_PROXY=ON
		fi

		CHOICES=$(whiptail --title "Nextcloud Talk HPB (Enterprise Linux)" --separate-output \
			--checklist "Select components (matches settings.sh / unattended when you pre-filled it).\n$(
			)• “Talk stack” = signaling (source), NATS, Janus. • “web” = nginx + Certbot on this host.\n$(
			)• External proxy: no nginx/Certbot here; point Traefik etc. at signaling (see tmp/reverse-proxy/)." 24 92 5 \
			"hpb" "Talk stack: nextcloud-spreed-signaling, NATS, Janus" "$_DEFAULT_HPB" \
			"fw"  "firewalld (open HTTP/HTTPS and Talk-related ports)" "$_DEFAULT_FW" \
			"web" "nginx + Certbot (Let’s Encrypt for this host’s FQDN)" "$_DEFAULT_WEB" \
			"turn" "Local coturn (TURN/STUN on this host)" "$_DEFAULT_TURN" \
			"pxy" "Behind Traefik / external HTTPS only (no nginx or Certbot here)" "$_DEFAULT_PROXY" \
			3>&1 1>&2 2>&3 || true)

		if [ -z "$CHOICES" ]; then
			log_err "No service was selected (user hit Cancel or unselected all options) Exiting…"
			exit 0
		else
			for CHOICE in $CHOICES; do
				case "$CHOICE" in
				"hpb")
					log "Talk HPB stack selected: nextcloud-spreed-signaling, NATS, Janus."
					SHOULD_INSTALL_SIGNALING=true
					;;
				"fw")
					log "firewalld will be configured for web / Talk as needed."
					SHOULD_INSTALL_FIREWALLD=true
					;;
				"web")
					log "nginx and Certbot will be installed for TLS on this host."
					SHOULD_INSTALL_NGINX=true
					SHOULD_INSTALL_CERTBOT=true
					;;
				"turn")
					log "Local coturn (TURN/STUN) will be installed."
					SHOULD_INSTALL_COTURN=true
					;;
				"pxy")
					log "Using an external reverse proxy: nginx and Certbot are skipped on this host."
					BEHIND_EXISTING_REVERSE_PROXY=true
					;;
				*)
					log_err "Unsupported checklist tag: $CHOICE" >&2
					exit 1
					;;
				esac
			done
		fi
		if [ "$SHOULD_INSTALL_COTURN" = true ] && [ "$SHOULD_INSTALL_SIGNALING" != true ]; then
			log "Local coturn requires the Talk stack; enabling signaling and firewalld."
			SHOULD_INSTALL_SIGNALING=true
			SHOULD_INSTALL_FIREWALLD=true
			if [ "$BEHIND_EXISTING_REVERSE_PROXY" != true ]; then
				SHOULD_INSTALL_NGINX=true
				SHOULD_INSTALL_CERTBOT=true
			fi
		fi
		if [ "$BEHIND_EXISTING_REVERSE_PROXY" = true ] && [ "$SHOULD_INSTALL_SIGNALING" != true ]; then
			log "External proxy mode needs the Talk stack on this host; enabling signaling and firewalld."
			SHOULD_INSTALL_SIGNALING=true
			SHOULD_INSTALL_FIREWALLD=true
		fi
		# Sensible defaults: web stack implies Talk + firewall for this project.
		if [ "$SHOULD_INSTALL_NGINX" = true ] || [ "$SHOULD_INSTALL_CERTBOT" = true ]; then
			if [ "$SHOULD_INSTALL_SIGNALING" != true ]; then
				log "TLS proxy role requires the Talk stack; enabling signaling and firewalld."
				SHOULD_INSTALL_SIGNALING=true
				SHOULD_INSTALL_FIREWALLD=true
			fi
		fi
	fi

	if [ "${BEHIND_EXISTING_REVERSE_PROXY:-}" = true ]; then
		SHOULD_INSTALL_NGINX=false
		SHOULD_INSTALL_CERTBOT=false
		log "External reverse proxy mode: nginx and Certbot are disabled on this host."
	fi

	show_dialogs

	log "Using '$EXTERNAL_IP_PRIMARY_ENDPOINT' for EXTERNAL_IP_PRIMARY_ENDPOINT."
	log "Using '$EXTERNAL_IP_FALLBACK_ENDPOINT' for EXTERNAL_IP_FALLBACK_ENDPOINT."
	log "Detecting external IPv4 and IPv6 addresses…"
	EXTERNAL_IPV4=$(fetch_external_ip_with_fallback 4) || log_err "Could not detect EXTERNAL_IPV4."
	EXTERNAL_IPV6=$(fetch_external_ip_with_fallback 6) || log_err "Could not detect EXTERNAL_IPV6."
	log "Using '$EXTERNAL_IPV4' for EXTERNAL_IPV4."
	log "Using '$EXTERNAL_IPV6' for EXTERNAL_IPV6."

	# Transform Nextcloud server URLs into array.
	# Change comma (,) to whitespace
	NEXTCLOUD_SERVER_FQDNS=($(echo "$NEXTCLOUD_SERVER_FQDNS" | tr ',' ' '))
	log "Splitting Nextcloud server domains into:"
	log "$(printf '\t- %s\n' "${NEXTCLOUD_SERVER_FQDNS[@]}")"

	is_dry_run &&
		log "Running in dry-mode. This script won't actually do anything on" \
			"your system!"

	if [ "$UNATTENDED_INSTALL" = true ]; then
		log "Trying unattented installation."
	fi

	if ! [ -e "$TMP_DIR_PATH" ]; then
		log "Creating '$TMP_DIR_PATH'."
		mkdir -p "$TMP_DIR_PATH" 2>&1 | tee -a $LOGFILE_PATH
	else
		log "Deleted contents of '$TMP_DIR_PATH'."
		rm -vr "$TMP_DIR_PATH"/* 2>&1 | tee -a $LOGFILE_PATH || true
	fi

	log "Moving config files into '$TMP_DIR_PATH'."
	cp -rv data/* "$TMP_DIR_PATH" 2>&1 | tee -a $LOGFILE_PATH

	log "Deleting every '127.0.1.1' entry in /etc/hosts."
	is_dry_run || sed -i "/127.0.1.1/d" /etc/hosts

	entry="127.0.1.1 $SERVER_FQDN $(hostname)"
	log "Deploying '$entry' in /etc/hosts."
	is_dry_run || echo "$entry" >>/etc/hosts

	scripts=('src/setup-firewalld.sh' 'src/setup-signaling.sh' 'src/setup-nginx.sh' 'src/setup-certbot.sh')
	for script in "${scripts[@]}"; do
		log "Sourcing '$script'."
		source "$script"
	done

	if [ "$SHOULD_INSTALL_FIREWALLD" = true ]; then install_firewalld; else
		log "Won't configure firewalld."
	fi
	if [ "$SHOULD_INSTALL_SIGNALING" = true ]; then install_signaling; else
		log "Won't install Signaling."
	fi
	if [ "$SHOULD_INSTALL_NGINX" = true ]; then install_nginx; else
		log "Won't install Nginx."
	fi
	if [ "$SHOULD_INSTALL_CERTBOT" = true ]; then install_certbot; else
		log "Won't install Certbot."
	fi

	if [ "${BEHIND_EXISTING_REVERSE_PROXY:-}" = true ]; then
		is_dry_run || mkdir -p "$TMP_DIR_PATH/reverse-proxy"
		local _sig_proxy_url="http://127.0.0.1:8080"
		if [[ "${SIGNALING_HTTP_LISTEN:-}" == 0.0.0.0:* ]] || [[ "${SIGNALING_HTTP_LISTEN:-}" == \[::\]:* ]]; then
			local _port="${SIGNALING_HTTP_LISTEN##*:}"
			_sig_proxy_url="http://REPLACE_WITH_THIS_HOST_LAN_IP:${_port}"
		elif [[ -n "${SIGNALING_HTTP_LISTEN:-}" ]]; then
			_sig_proxy_url="http://${SIGNALING_HTTP_LISTEN}"
		fi
		if is_dry_run; then
			log "Would write Traefik example to $TMP_DIR_PATH/reverse-proxy/traefik-dynamic.${SERVER_FQDN}.yml"
		else
			sed -e "s|<SERVER_FQDN>|$SERVER_FQDN|g" -e "s|<SIGNALING_HTTP_PROXY_URL>|$_sig_proxy_url|g" \
				data/reverse-proxy/traefik-dynamic.example.yml \
				>"$TMP_DIR_PATH/reverse-proxy/traefik-dynamic.${SERVER_FQDN}.yml"
			log "======================================================================"
			log "Traefik example (file provider) written to:"
			log "  ${cyan}$TMP_DIR_PATH/reverse-proxy/traefik-dynamic.${SERVER_FQDN}.yml${normal}"
			log "Point Talk HPB to: ${cyan}https://${SERVER_FQDN}/standalone-signaling${normal}"
			log "If the proxy is not on this machine, set SIGNALING_HTTP_LISTEN (e.g. 0.0.0.0:8080) and fix the URL in the YAML."
			log "======================================================================"
		fi
	fi

	log "Every installation completed."

	if [ "$DISABLE_SSH_SERVER" = true ]; then
		log "Disabling SSH service…"
		is_dry_run || systemctl disable sshd 2>/dev/null || systemctl disable ssh 2>/dev/null || true
	fi

	log "Enabling and restarting services…"
	SERVICES_TO_ENABLE=()
	if [ "$SHOULD_INSTALL_FIREWALLD" = true ]; then
		SERVICES_TO_ENABLE+=("firewalld")
	fi
	if [ "$SHOULD_INSTALL_SIGNALING" = true ]; then
		if [ "$SHOULD_INSTALL_COTURN" = true ]; then
			SERVICES_TO_ENABLE+=("coturn")
		fi
		SERVICES_TO_ENABLE+=("nats-server" "nextcloud-spreed-signaling" "janus")
	fi
	#if [ "$SHOULD_INSTALL_CERTBOT" = true ]; then fi
	if [ "$SHOULD_INSTALL_NGINX" = true ]; then
		SERVICES_TO_ENABLE+=("nginx")
	fi
	SERVICE_ERRORS=()
	if ! is_dry_run; then
		for i in "${SERVICES_TO_ENABLE[@]}"; do
			log "Enabling and restarting service '$i'…"
			if ! systemctl unmask "$i" 2>&1 | tee -a $LOGFILE_PATH; then
				SERVICE_ERRORS+=("Failed to unmask service '$i'")
			fi

			if ! service "$i" stop 2>&1 | tee -a $LOGFILE_PATH; then
				SERVICE_ERRORS+=("Failed to stop service '$i'")
			fi

			if ! systemctl enable --now "$i" 2>&1 | tee -a $LOGFILE_PATH; then
				SERVICE_ERRORS+=("Failed to enable/start service '$i'")
			fi
			sleep 0.25s
		done
	fi

	log "======================================================================"
	if [ "$SHOULD_INSTALL_SIGNALING" = true ]; then
		signaling_print_info
		log "======================================================================"
	fi
	if [ "$SHOULD_INSTALL_CERTBOT" = true ]; then
		certbot_print_info
		log "======================================================================"
	fi
	if [ "$SHOULD_INSTALL_NGINX" = true ]; then
		nginx_print_info
		log "======================================================================"
	fi
	is_dry_run || mkdir -p "$(dirname "$SECRETS_FILE_PATH")"
	is_dry_run || touch "$SECRETS_FILE_PATH"
	is_dry_run || chmod 0640 "$SECRETS_FILE_PATH"

	echo -e "This file contains secrets, passwords and configuration" \
		"generated by the Nextcloud High-Performance backend setup." \
		>$SECRETS_FILE_PATH
	if [ "$SHOULD_INSTALL_SIGNALING" = true ]; then
		signaling_write_secrets_to_file "$SECRETS_FILE_PATH"
	fi
	if [ "$SHOULD_INSTALL_CERTBOT" = true ]; then
		certbot_write_secrets_to_file "$SECRETS_FILE_PATH"
	fi
	if [ "$SHOULD_INSTALL_NGINX" = true ]; then
		nginx_write_secrets_to_file "$SECRETS_FILE_PATH"
	fi
	# Display service errors summary if any occurred
	if [ ${#SERVICE_ERRORS[@]} -gt 0 ]; then
		log ""
		log "======================================================================"
		log_err "The following service management errors occurred:"
		for error in "${SERVICE_ERRORS[@]}"; do
			log_err "  - $error"
		done
		log_err "Please check the services manually using 'systemctl status <service-name>'"
		log "======================================================================"
		log ""
	fi

	log "\nThank you for using this script.\n"
}

# Execute main function.
main "$1"

set +eo pipefail
