#!/bin/bash

# Signaling server
# https://github.com/strukturag/nextcloud-spreed-signaling

SIGNALING_TURN_STATIC_AUTH_SECRET="$(openssl rand -hex 32)"
SIGNALING_JANUS_API_KEY="$(openssl rand -base64 16)"
SIGNALING_HASH_KEY="$(openssl rand -hex 16)"
SIGNALING_BLOCK_KEY="$(openssl rand -hex 16)"

SIGNALING_COTURN_URL="$SERVER_FQDN"

COTURN_DIR="/etc/coturn"

declare -a SIGNALING_BACKENDS                   # Normal array
declare -a SIGNALING_BACKEND_DEFINITIONS        # Normal Array
declare -A SIGNALING_NC_SERVER_SECRETS          # Associative array
declare -A SIGNALING_NC_SERVER_SESSIONLIMIT     # Associative array
declare -A SIGNALING_NC_SERVER_MAXSTREAMBITRATE # Associative array
declare -A SIGNALING_NC_SERVER_MAXSCREENBITRATE # Associative array

# meetecho/janus-gateway release when no 'janus' RPM exists (typical on EL 10+).
JANUS_SOURCE_TAG="v1.2.2"

# Helper function to check if a package needs rebuilding based on version
# Usage: should_skip_build "marker_file" "current_version" "binary_path"
# Returns 0 (true) if build should be skipped, 1 (false) if build is needed
function should_skip_build() {
	local marker_file="$1"
	local current_version="$2"
	local binary_path="$3"

	# Binary must exist
	[[ ! -x "$binary_path" ]] && return 1

	# No marker = must build
	[[ ! -f "$marker_file" ]] && return 1

	local built_version="$(cat "$marker_file")"

	# Simple comparison: if marker content equals current version, skip
	[[ "$built_version" = "$current_version" ]] && return 0

	# Different version = must build
	return 1
}

# Helper function to run a command with animated progress dots
# Usage: run_with_progress "Message" "command to run"
# Supports error handling: run_with_progress "..." "..." || true
function run_with_progress() {
	local message="$1"
	local command="$2"
	local temp_log=$(mktemp)

	# Log the command being executed (helpful for debugging)
	{ echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running: $command"; } >> "$LOGFILE_PATH" 2>/dev/null || true

	# Start the command in background, redirecting output to temp log
	eval "$command" > "$temp_log" 2>&1 &
	local pid=$!

	# Show animated progress
	printf "%s" "${blue}$message"
	while kill -0 $pid 2>/dev/null; do
		printf "."
		sleep 0.5
	done

	# Wait for the process to finish and get exit code
	wait $pid
	local exit_code=$?

	# Show success or failure
	if [ $exit_code -eq 0 ]; then
		printf " ${green}✓${normal}\n"
	else
		printf " ${red}✗ FAILED${normal}\n"

		# Show last lines of output for context
		log_err "Error output (last 15 lines):"
		tail -n 15 "$temp_log" >&2
		log_err "Full log available in: $LOGFILE_PATH"
	fi

	# Always append to log file (do not fail the install if the log is not writable)
	cat "$temp_log" >> "$LOGFILE_PATH" 2>/dev/null || true
	echo "" >> "$LOGFILE_PATH" 2>/dev/null || true

	# Cleanup
	rm -f "$temp_log"

	# Return the exit code (allows || true pattern)
	return $exit_code
}

# Clear failure exit after a nextcloud-spreed-signaling build step (run_with_progress already printed the tail of stderr).
function signaling_build_nss_fail() {
	log_err "nextcloud-spreed-signaling: $*"
	log_err "Full transcript: $LOGFILE_PATH"
	exit 1
}

function signaling_ensure_epel_repos() {
	# EPEL (and CRB / PowerTools on RHEL-family) for coturn, janus, build tools. NATS may be missing (EL 10+); see signaling_install_nats.
	if is_dry_run; then
		return 0
	fi
	if ! rpm -q epel-release &>/dev/null; then
		log "Installing EPEL release package…"
		local rhel
		rhel=$(rpm -E '%{rhel}' 2>/dev/null || echo "")
		if [[ "$rhel" =~ ^[0-9]+$ ]]; then
			dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel}.noarch.rpm" 2>&1 | tee -a "$LOGFILE_PATH" \
				|| dnf install -y epel-release 2>&1 | tee -a "$LOGFILE_PATH" || true
		else
			dnf install -y epel-release 2>&1 | tee -a "$LOGFILE_PATH" || true
		fi
	fi
	if rpm --quiet -q centos-stream-release 2>/dev/null || rpm --quiet -q redhat-release 2>/dev/null \
		|| rpm --quiet -q almalinux-release 2>/dev/null || rpm --quiet -q rocky-release 2>/dev/null; then
		dnf config-manager --set-enabled crb 2>/dev/null || dnf config-manager --set-enabled powertools 2>/dev/null || true
	fi
}

# Prefer distro nats-server (e.g. EPEL 9). On EL 10+ the RPM is often missing — install upstream binary + our systemd unit.
function signaling_install_nats() {
	local dnf_params="${1:--y}"
	if is_dry_run; then
		log "Would install NATS Server (repository package or official binary)…"
		return 0
	fi
	if dnf install $dnf_params nats-server 2>&1 | tee -a "$LOGFILE_PATH"; then
		log "Installed nats-server from enabled repositories."
		return 0
	fi

	log "The 'nats-server' package was not found in enabled repositories. Installing the official Linux build from GitHub (same as nats.io releases)…"
	if [ -x /usr/local/bin/nats-server ]; then
		log "Found existing /usr/local/bin/nats-server; refreshing config and unit…"
	else
		local tag arch url work binone
		tag=$(curl -sL "https://api.github.com/repos/nats-io/nats-server/releases/latest" | jq -r ".tag_name // empty")
		if [ -z "$tag" ] || [ "$tag" = "null" ]; then
			log_err "Could not read latest nats-server release from the GitHub API (need curl and jq, and outbound HTTPS)."
			exit 1
		fi
		case "$(uname -m)" in
		x86_64) arch=amd64 ;;
		aarch64) arch=arm64 ;;
		ppc64le) arch=ppc64le ;;
		s390x) arch=s390x ;;
		*)
			log_err "No upstream nats.io Linux build mapping for: $(uname -m)"
			exit 1
			;;
		esac
		url="https://github.com/nats-io/nats-server/releases/download/${tag}/nats-server-${tag}-linux-${arch}.tar.gz"
		work=$(mktemp -d) || exit 1
		(
			set -e
			cd "$work" || exit 1
			wget -nv "$url" -O nats-upstream.tgz
			tar -xf nats-upstream.tgz
			if [ -f ./nats-server ]; then
				binone=./nats-server
			else
				binone=$(find . -name nats-server -type f -print -quit 2>/dev/null)
			fi
			[ -n "$binone" ] && [ -f "$binone" ] || exit 1
			install -m 0755 "$binone" /usr/local/bin/nats-server
		) 2>&1 | tee -a "$LOGFILE_PATH"
		if [ "${PIPESTATUS[0]}" -ne 0 ]; then
			log_err "Failed to download or install the upstream nats-server binary from GitHub. See: $LOGFILE_PATH"
			rm -rf "$work"
			exit 1
		fi
		rm -rf "$work"
		log "Installed nats-server (${tag}) to /usr/local/bin/nats-server"
	fi

	if ! getent passwd nats &>/dev/null; then
		useradd -r -U -d /var/lib/nats -s /sbin/nologin nats 2>&1 | tee -a "$LOGFILE_PATH" || true
	fi

	deploy_file "$TMP_DIR_PATH"/signaling/nats-server.conf /etc/nats-server.conf || true
	deploy_file "$TMP_DIR_PATH"/signaling/nats-server.service /lib/systemd/system/nats-server.service || true
}

function install_signaling() {
	announce_installation "Installing Signaling (Talk HPB)"
	log "Installing Signaling…"
	local LANG=C

	DNF_PARAMS="-y"
	if [ "$UNATTENDED_INSTALL" == true ]; then
		log "Trying unattended install for Signaling."
		DNF_PARAMS="-y -q"
	fi

	is_dry_run || dnf makecache 2>&1 | tee -a "$LOGFILE_PATH" || true
	is_dry_run || signaling_ensure_epel_repos

	log "Removing distro nextcloud-spreed-signaling if present (we always build the signaling server from source)…"
	for pkg in nextcloud-spreed-signaling; do
		if is_dry_run; then
			log "Would remove package: $pkg"
			continue
		fi
		dnf remove -y "$pkg" 2>&1 | tee -a "$LOGFILE_PATH" || true
	done

	log "Installing Signaling build dependencies…"
	is_dry_run || dnf install $DNF_PARAMS wget curl tar jq protobuf-compiler gcc gcc-c++ make golang-bin git \
		openssl openssl-devel 2>&1 | tee -a "$LOGFILE_PATH"

	is_dry_run "Would have built nextcloud-spreed-signaling now…" || signaling_build_nextcloud-spreed-signaling

	log "Installing NATS, Janus RPM, and optional coturn…"
	is_dry_run || signaling_install_nats "$DNF_PARAMS"
	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		is_dry_run || dnf install $DNF_PARAMS coturn 2>&1 | tee -a "$LOGFILE_PATH"
	fi

	is_dry_run "Would have installed Janus now…" || signaling_install_janus "$DNF_PARAMS"

	log "Reloading systemd."
	is_dry_run || systemctl daemon-reload | tee -a "$LOGFILE_PATH"

	signaling_step4
	signaling_step5

	# Delay Janus start after reboot when coturn runs locally (avoids Janus/coturn ordering on boot).
	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		set +eo pipefail
		crontab -l 2>/dev/null >cron_backup || touch cron_backup
		if ! grep -q "systemctl restart janus" cron_backup 2>/dev/null; then
			echo "@reboot sleep 15 && systemctl restart janus > /dev/null 2>&1" >>cron_backup
			is_dry_run || crontab cron_backup
		fi
		rm -f cron_backup
		set -eo pipefail
	fi

	log "Signaling install completed."
}

# Prefer RPM (EPEL, etc.); on EL 10+ there is often no janus package — build from meetecho/janus-gateway.
function signaling_install_janus() {
	local dnf_params="${1:--y}"
	[ -z "$dnf_params" ] && dnf_params="-y"
	if is_dry_run; then
		return 0
	fi
	if command -v janus &>/dev/null; then
		log "Janus is already on PATH ($(command -v janus))."
		return 0
	fi
	if dnf install $dnf_params janus 2>&1 | tee -a "$LOGFILE_PATH"; then
		log "Installed Janus from enabled repositories."
		return 0
	fi

	if [ -f /var/lib/nextcloud-hpb-setup/janus-built-from-source ] \
		&& [ "$(tr -d '\n' </var/lib/nextcloud-hpb-setup/janus-built-from-source 2>/dev/null)" = "$JANUS_SOURCE_TAG" ] \
		&& [ -x /usr/bin/janus ]; then
		log "Using previously built Janus at /usr/bin/janus (tag $JANUS_SOURCE_TAG)."
		is_dry_run || deploy_file "$TMP_DIR_PATH"/signaling/janus.service /lib/systemd/system/janus.service || true
		return 0
	fi

	log "No 'janus' package in your repositories; building Janus $JANUS_SOURCE_TAG from source (takes several minutes)…"
	signaling_build_janus_from_source
}

function signaling_build_janus_from_source() {
	if is_dry_run; then
		return 0
	fi
	local work
	work=$(mktemp -d "${TMPDIR:-/tmp}/janus-gw-build.XXXXXX") || {
		log_err "Could not create a temp build directory for Janus."
		exit 1
	}
	log "Installing build dependencies for Janus…"
	# AppStream/CRB use RHEL names: 'opus-devel' (not libopus-devel), 'libsrtp-devel' (1.5.x) if libsrtp2 is absent.
	# EPEL10 may not ship sofia-sip-devel — Talk does not need the SIP plugin; we pass --disable-plugin-sip.
	# shellcheck disable=SC2086
	if ! dnf install $DNF_PARAMS gcc gcc-c++ make automake autoconf libtool which pkgconf-pkg-config git \
		jansson-devel glib2-devel libconfig-devel zlib-devel openssl-devel \
		libcurl-devel libmicrohttpd-devel libwebsockets-devel libnice-devel libsrtp-devel \
		libogg-devel opus-devel speex speexdsp-devel \
		gengetopt 2>&1 | tee -a "$LOGFILE_PATH"; then
		log_err "Could not install Janus build dependencies. Enable EPEL, CRB/PowerTools, and try: dnf install <packages above>. See: $LOGFILE_PATH"
		rm -rf "$work"
		exit 1
	fi
	# Optional (improve SRTP 2 / SCTP data channels when packages exist in your repos).
	# shellcheck disable=SC2086
	dnf install $DNF_PARAMS libsrtp2-devel libusrsctp-devel 2>&1 | tee -a "$LOGFILE_PATH" || true

	# Configure flags: Talk uses videoroom + WebSockets (no SIP stack). SRTP 1.5 is fine when SRTP2 is absent.
	_JANUS_CONF="--prefix=/usr --sysconfdir=/etc --disable-plugin-sip"
	if ! pkg-config --exists libsrtp2 2>/dev/null; then
		_JANUS_CONF="$_JANUS_CONF --disable-libsrtp2"
		log "Using libsrtp 1.x from libsrtp-devel (no pkg-config libsrtp2); Janus gets --disable-libsrtp2."
	fi
	# Optional second dnf may have failed; AC_CHECK_LIB needs libusrsctp at link time or --disable-data-channels.
	if ! rpm -q libusrsctp-devel &>/dev/null; then
		_JANUS_CONF="$_JANUS_CONF --disable-data-channels"
		log "libusrsctp-devel not installed; pass --disable-data-channels (install it for SCTP data channels)."
	fi

	(
		set -e
		cd "$work"
		# --depth 1: shallow clone; tag must exist on GitHub.
		git clone --depth 1 -b "$JANUS_SOURCE_TAG" https://github.com/meetecho/janus-gateway.git
		cd janus-gateway
		./autogen.sh
		# shellcheck disable=SC2086
		./configure $_JANUS_CONF
		"$(command -v make)" -j"$(nproc)"
		"$(command -v make)" install
	) 2>&1 | tee -a "$LOGFILE_PATH"
	if [ "${PIPESTATUS[0]}" -ne 0 ]; then
		log_err "Janus build or install failed. See config.log in the build tree if present and: $LOGFILE_PATH"
		rm -rf "$work"
		exit 1
	fi
	ldconfig 2>/dev/null || true
	rm -rf "$work"
	is_dry_run || mkdir -p /var/lib/nextcloud-hpb-setup
	is_dry_run || echo -n "$JANUS_SOURCE_TAG" >/var/lib/nextcloud-hpb-setup/janus-built-from-source
	log "Janus $JANUS_SOURCE_TAG installed to /usr/bin/janus"
	is_dry_run || deploy_file "$TMP_DIR_PATH"/signaling/janus.service /lib/systemd/system/janus.service || true
}

function signaling_build_nextcloud-spreed-signaling() {
	log "[Building n-s-s] Building nextcloud-spreed-signaling…"

	# Check if nextcloud-spreed-signaling is already installed
	NSS_BUILD_MARKER="/var/lib/nextcloud-hpb-setup/nextcloud-spreed-signaling-built-version"

	log "[Building n-s-s] Fetching latest commit hash from GitHub…"
	NSS_COMMIT=$(curl -s https://api.github.com/repos/strukturag/nextcloud-spreed-signaling/commits/master | jq -r '.sha // empty' 2>/dev/null)

	if [ -z "$NSS_COMMIT" ]; then
		log_err "[Building n-s-s] ERROR: Could not fetch latest commit hash from GitHub!"
		exit 1
	fi

	NSS_VERSION="master-${NSS_COMMIT:0:8}"
	log "[Building n-s-s] Latest n-s-s version: $NSS_VERSION"

	# Check if already built with this version
	if should_skip_build "$NSS_BUILD_MARKER" "$NSS_VERSION" "/usr/local/bin/nextcloud-spreed-signaling-server"; then
		log "[Building n-s-s] nextcloud-spreed-signaling $NSS_VERSION is already built and installed. Skipping build."
		return 0
	fi

	log "[Building n-s-s] Downloading sources…"
	is_dry_run || rm -f n-s-s-master.tar.gz
	if ! is_dry_run; then
		if ! run_with_progress "[Building n-s-s] Downloading source archive" "wget -nv https://github.com/strukturag/nextcloud-spreed-signaling/archive/refs/heads/master.tar.gz -O n-s-s-master.tar.gz"; then
			signaling_build_nss_fail "Download of the signaling server source failed (see log). Check network and TLS access to github.com."
		fi
	fi

	log "[Building n-s-s] Extracting sources…"
	if ! is_dry_run; then
		if ! run_with_progress "[Building n-s-s] Extracting source archive" "tar -xf n-s-s-master.tar.gz"; then
			signaling_build_nss_fail "Extraction of the source archive failed (disk full, corrupt download, or missing tar). See log for details."
		fi
		# Resolve source dir on disk (do not use head/cut/tar -tf here: with set -e a missing head(1) exits the whole script with no message).
		shopt -s nullglob
		local -a _nss_glob=( nextcloud-spreed-signaling-*/ )
		shopt -u nullglob
		if [ "${#_nss_glob[@]}" -ne 1 ] || [ ! -d "${_nss_glob[0]}" ]; then
			signaling_build_nss_fail "Expected exactly one nextcloud-spreed-signaling-* directory after extract; found ${#_nss_glob[@]}. Remove n-s-s-master.tar.gz and any nextcloud-spreed-signaling-* dirs, then retry."
		fi
		NSS_SRC_DIR=${_nss_glob[0]%/}
	fi

	log "[Building n-s-s] Building sources (Go will download module dependencies; outbound HTTPS to proxy.golang.org and VCS hosts must be allowed)…"
	if ! is_dry_run; then
		# The Makefile runs go build; modules are fetched from the network on first build.
		if ! run_with_progress "[Building n-s-s] Compiling (this may take several minutes)" "make -C \"${NSS_SRC_DIR}\""; then
			signaling_build_nss_fail "Compile failed. This host needs working outbound HTTPS (Go modules). See log; on limited networks set GOPROXY and try again, or pre-populate the module cache."
		fi
	fi

	log "[Building n-s-s] Stopping potentially running service…"
	systemctl stop nextcloud-spreed-signaling 2>&1 | tee -a "$LOGFILE_PATH" || true

	log "[Building n-s-s] Copying built binary into /usr/local/bin/nextcloud-spreed-signaling-server…"
	is_dry_run || cp -v "$NSS_SRC_DIR"/bin/signaling \
		/usr/local/bin/nextcloud-spreed-signaling-server 2>&1 | tee -a "$LOGFILE_PATH"

	deploy_file "$TMP_DIR_PATH"/signaling/nextcloud-spreed-signaling.service \
		/lib/systemd/system/nextcloud-spreed-signaling.service || true

	if [ ! -d /etc/nextcloud-spreed-signaling ]; then
		log "[Building n-s-s] Creating '/etc/nextcloud-spreed-signaling' directory"
		mkdir /etc/nextcloud-spreed-signaling | tee -a $LOGFILE_PATH
	fi

	log "[Building n-s-s] Creating '_signaling' system user"
	if ! is_dry_run; then
		if ! id -u _signaling &>/dev/null; then
			useradd -r -U -d /var/lib/nextcloud-spreed-signaling --badname _signaling 2>&1 | tee -a "$LOGFILE_PATH" \
				|| useradd -r -U -d /var/lib/nextcloud-spreed-signaling _signaling 2>&1 | tee -a "$LOGFILE_PATH" || true
		fi
	fi

	# Mark this version as built
	if ! is_dry_run; then
		mkdir -p "$(dirname "$NSS_BUILD_MARKER")"
		echo "$NSS_VERSION" > "$NSS_BUILD_MARKER"
		log "[Building n-s-s] Marked version $NSS_VERSION as built in $NSS_BUILD_MARKER"
	fi
}

function signaling_fix_janus_plugin_paths_for_enterprise_linux() {
	# After Janus is installed (RPM or from source), plugin libraries live under /usr/lib64/janus on Enterprise Linux.
	[ -d /usr/lib64/janus ] || return 0
	local jf
	for jf in "$TMP_DIR_PATH"/signaling/janus.jcfg "$TMP_DIR_PATH"/signaling/janus_aarch64.jcfg "$TMP_DIR_PATH"/signaling/janus_powerpc64le.jcfg; do
		[ -f "$jf" ] || continue
		sed -i 's|/usr/lib/x86_64-linux-gnu/janus|/usr/lib64/janus|g' "$jf"
		sed -i 's|/usr/lib/aarch64-linux-gnu/janus|/usr/lib64/janus|g' "$jf"
		sed -i 's|/usr/lib/powerpc64le-linux-gnu/janus|/usr/lib64/janus|g' "$jf"
	done
}

function signaling_step4() {
	log "\n${green}Step 4: Prepare configuration"

	if [ -z "${SIGNALING_HTTP_LISTEN:-}" ]; then
		SIGNALING_HTTP_LISTEN="127.0.0.1:8080"
	fi
	log "Signaling HTTP listen address: '$SIGNALING_HTTP_LISTEN' (set SIGNALING_HTTP_LISTEN in settings for remote reverse proxies)."
	sed -i "s|<SIGNALING_HTTP_LISTEN>|$SIGNALING_HTTP_LISTEN|g" "$TMP_DIR_PATH"/signaling/signaling-server.conf

	if [ "$SHOULD_INSTALL_NGINX" = true ]; then
		is_dry_run || mkdir -p /etc/nginx/snippets || true
	fi

	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		if [ "$SHOULD_INSTALL_CERTBOT" = true ] && ! is_dry_run; then
			mkdir -p "$COTURN_DIR/certs"
			if getent group nginx &>/dev/null && id turnserver &>/dev/null 2>/dev/null; then
				usermod -aG nginx turnserver 2>/dev/null || true
			fi
		else
			is_dry_run || mkdir -p "$COTURN_DIR"
		fi
		generate_dhparam_file
		is_dry_run || chown -R turnserver:turnserver "$COTURN_DIR"
		is_dry_run || chmod -R 740 "$COTURN_DIR"
	else
		log "Skipping coturn TLS material (local TURN/STUN not selected)."
		generate_dhparam_file
	fi

	i=0
	for NC_SERVER in "${NEXTCLOUD_SERVER_FQDNS[@]}"; do
		NC_SERVER_UNDERSCORE=$(echo "$NC_SERVER" | sed "s/\./_/g")
		SIGNALING_NC_SERVER_SECRETS[$NC_SERVER_UNDERSCORE]="$(openssl rand -hex 16)"
		SIGNALING_NC_SERVER_SESSIONLIMIT[$NC_SERVER_UNDERSCORE]=0
		SIGNALING_NC_SERVER_MAXSTREAMBITRATE[$NC_SERVER_UNDERSCORE]=0
		SIGNALING_NC_SERVER_MAXSCREENBITRATE[$NC_SERVER_UNDERSCORE]=0

		SIGNALING_BACKENDS+=("nextcloud-backend-$i")

		IFS= read -r -d '' SIGNALING_BACKEND_DEFINITION <<-EOF || true
			[nextcloud-backend-$i]
			url = https://$NC_SERVER
			secret = ${SIGNALING_NC_SERVER_SECRETS["$NC_SERVER_UNDERSCORE"]}
			#sessionlimit = ${SIGNALING_NC_SERVER_SESSIONLIMIT["$NC_SERVER_UNDERSCORE"]}
			#maxstreambitrate = ${SIGNALING_NC_SERVER_MAXSTREAMBITRATE["$NC_SERVER_UNDERSCORE"]}
			#maxscreenbitrate = ${SIGNALING_NC_SERVER_MAXSCREENBITRATE["$NC_SERVER_UNDERSCORE"]}
		EOF

		# Escape newlines for sed later on.
		SIGNALING_BACKEND_DEFINITION=$(echo "$SIGNALING_BACKEND_DEFINITION" | sed -z 's|\n|\\n|g')
		SIGNALING_BACKEND_DEFINITIONS+=("$SIGNALING_BACKEND_DEFINITION")

		i=$(($i + 1))
	done

	# Don't actually *log* passwords! (Or do for debugging…)

	# log "Replacing '<SIGNALING_TURN_STATIC_AUTH_SECRET>' with '$SIGNALING_TURN_STATIC_AUTH_SECRET'…"
	log "Replacing '<SIGNALING_TURN_STATIC_AUTH_SECRET>'…"
	sed -i "s|<SIGNALING_TURN_STATIC_AUTH_SECRET>|$SIGNALING_TURN_STATIC_AUTH_SECRET|g" "$TMP_DIR_PATH"/signaling/*

	# log "Replacing '<SIGNALING_JANUS_API_KEY>' with '$SIGNALING_JANUS_API_KEY'…"
	log "Replacing '<SIGNALING_JANUS_API_KEY>…'"
	sed -i "s|<SIGNALING_JANUS_API_KEY>|$SIGNALING_JANUS_API_KEY|g" "$TMP_DIR_PATH"/signaling/*

	# log "Replacing '<SIGNALING_HASH_KEY>' with '$SIGNALING_HASH_KEY'…"
	log "Replacing '<SIGNALING_HASH_KEY>…'"
	sed -i "s|<SIGNALING_HASH_KEY>|$SIGNALING_HASH_KEY|g" "$TMP_DIR_PATH"/signaling/*

	# log "Replacing '<SIGNALING_BLOCK_KEY>' with '$SIGNALING_BLOCK_KEY'…"
	log "Replacing '<SIGNALING_BLOCK_KEY>…'"
	sed -i "s|<SIGNALING_BLOCK_KEY>|$SIGNALING_BLOCK_KEY|g" "$TMP_DIR_PATH"/signaling/*

	IFS=,
	log "Replacing '<SIGNALING_BACKENDS>' with '""${SIGNALING_BACKENDS[*]}""'…"
	sed -i "s|<SIGNALING_BACKENDS>|""${SIGNALING_BACKENDS[*]}""|g" "$TMP_DIR_PATH"/signaling/*
	unset IFS

	IFS= # Avoid whitespace between definitions.
	#log "Replacing '<SIGNALING_BACKEND_DEFINITIONS>' with:\n${SIGNALING_BACKEND_DEFINITIONS[*]}"
	log "Replacing '<SIGNALING_BACKEND_DEFINITIONS>'…"
	sed -ri "s|<SIGNALING_BACKEND_DEFINITIONS>|${SIGNALING_BACKEND_DEFINITIONS[*]}|g" "$TMP_DIR_PATH"/signaling/*
	unset IFS

	log "Replacing '<SIGNALING_COTURN_URL>' with '$SIGNALING_COTURN_URL'…"
	sed -i "s|<SIGNALING_COTURN_URL>|$SIGNALING_COTURN_URL|g" "$TMP_DIR_PATH"/signaling/*

	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		SIGNALING_TURN_SERVERS="turn:${SIGNALING_COTURN_URL}:9991?transport=udp,turn:${SIGNALING_COTURN_URL}:9991?transport=tcp"
		JANUS_STUN_SERVER="$SIGNALING_COTURN_URL"
		JANUS_STUN_PORT="5349"
	else
		SIGNALING_TURN_SERVERS=""
		JANUS_STUN_SERVER="stun.l.google.com"
		JANUS_STUN_PORT="19302"
	fi
	log "TURN REST API server list: ${SIGNALING_TURN_SERVERS:-<empty — configure Talk STUN/TURN if needed>}"
	replace_placeholder_in_files "<SIGNALING_TURN_SERVERS>" "$SIGNALING_TURN_SERVERS" "$TMP_DIR_PATH"/signaling/signaling-server.conf
	sed -i "s|<JANUS_STUN_SERVER>|$JANUS_STUN_SERVER|g" "$TMP_DIR_PATH"/signaling/janus.jcfg \
		"$TMP_DIR_PATH"/signaling/janus_aarch64.jcfg "$TMP_DIR_PATH"/signaling/janus_powerpc64le.jcfg
	sed -i "s|<JANUS_STUN_PORT>|$JANUS_STUN_PORT|g" "$TMP_DIR_PATH"/signaling/janus.jcfg \
		"$TMP_DIR_PATH"/signaling/janus_aarch64.jcfg "$TMP_DIR_PATH"/signaling/janus_powerpc64le.jcfg
	if [ "$SHOULD_INSTALL_COTURN" != true ]; then
		for jf in "$TMP_DIR_PATH"/signaling/janus.jcfg "$TMP_DIR_PATH"/signaling/janus_aarch64.jcfg "$TMP_DIR_PATH"/signaling/janus_powerpc64le.jcfg; do
			[ -f "$jf" ] || continue
			sed -i 's/^\(\t\)turn_rest_api_key/\1#turn_rest_api_key/' "$jf"
		done
	fi

	log "Replacing '<SSL_CERT_PATH_RSA>' with '$SSL_CERT_PATH_RSA'…"
	sed -i "s|<SSL_CERT_PATH_RSA>|$SSL_CERT_PATH_RSA|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SSL_CERT_KEY_PATH_RSA>' with '$SSL_CERT_KEY_PATH_RSA'…"
	sed -i "s|<SSL_CERT_KEY_PATH_RSA>|$SSL_CERT_KEY_PATH_RSA|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SSL_CHAIN_PATH_RSA>' with '$SSL_CHAIN_PATH_RSA'…"
	sed -i "s|<SSL_CHAIN_PATH_RSA>|$SSL_CHAIN_PATH_RSA|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SSL_CERT_PATH_ECDSA>' with '$SSL_CERT_PATH_ECDSA'…"
	sed -i "s|<SSL_CERT_PATH_ECDSA>|$SSL_CERT_PATH_ECDSA|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SSL_CERT_KEY_PATH_ECDSA>' with '$SSL_CERT_KEY_PATH_ECDSA'…"
	sed -i "s|<SSL_CERT_KEY_PATH_ECDSA>|$SSL_CERT_KEY_PATH_ECDSA|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SSL_CHAIN_PATH_ECDSA>' with '$SSL_CHAIN_PATH_ECDSA'…"
	sed -i "s|<SSL_CHAIN_PATH_ECDSA>|$SSL_CHAIN_PATH_ECDSA|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<DHPARAM_PATH>' with '$DHPARAM_PATH'…"
	sed -i "s|<DHPARAM_PATH>|$DHPARAM_PATH|g" "$TMP_DIR_PATH"/signaling/*

	SIGNALING_COTURN_LISTENING_IPV4_LINE=""
	if [ -n "$EXTERNAL_IPV4" ]; then
		SIGNALING_COTURN_LISTENING_IPV4_LINE="listening-ip=$EXTERNAL_IPV4"
	fi
	log "Replacing '<SIGNALING_COTURN_LISTENING_IPV4_LINE>' with '$SIGNALING_COTURN_LISTENING_IPV4_LINE'…"
	sed -i "s|<SIGNALING_COTURN_LISTENING_IPV4_LINE>|$SIGNALING_COTURN_LISTENING_IPV4_LINE|g" "$TMP_DIR_PATH"/signaling/*

	SIGNALING_COTURN_LISTENING_IPV6_LINE=""
	if [ -n "$EXTERNAL_IPV6" ]; then
		SIGNALING_COTURN_LISTENING_IPV6_LINE="listening-ip=$EXTERNAL_IPV6"
	fi
	log "Replacing '<SIGNALING_COTURN_LISTENING_IPV6_LINE>' with '$SIGNALING_COTURN_LISTENING_IPV6_LINE'…"
	sed -i "s|<SIGNALING_COTURN_LISTENING_IPV6_LINE>|$SIGNALING_COTURN_LISTENING_IPV6_LINE|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SIGNALING_COTURN_EXTERN_IPV4>' with '$EXTERNAL_IPV4'…"
	sed -i "s|<SIGNALING_COTURN_EXTERN_IPV4>|$EXTERNAL_IPV4|g" "$TMP_DIR_PATH"/signaling/*

	log "Replacing '<SIGNALING_COTURN_EXTERN_IPV6>' with '$EXTERNAL_IPV6'…"
	sed -i "s|<SIGNALING_COTURN_EXTERN_IPV6>|$EXTERNAL_IPV6|g" "$TMP_DIR_PATH"/signaling/*

	# Templates use Debian multilib paths; RHEL/Alma/Rocky/Fedora use /usr/lib64/janus.
	signaling_fix_janus_plugin_paths_for_enterprise_linux
}

function signaling_step5() {
	log "\n${green}Step 5: Deploy configuration"

	if [ "$SHOULD_INSTALL_NGINX" = true ]; then
		deploy_file "$TMP_DIR_PATH"/signaling/nginx-signaling-upstream-servers.conf /etc/nginx/snippets/signaling-upstream-servers.conf || true
		deploy_file "$TMP_DIR_PATH"/signaling/nginx-signaling-forwarding.conf /etc/nginx/snippets/signaling-forwarding.conf || true
	fi

	# Ensure /etc/janus directory exists
	is_dry_run || mkdir -p /etc/janus

	case "$(uname -m)" in
	aarch64)
		deploy_file "$TMP_DIR_PATH"/signaling/janus_aarch64.jcfg /etc/janus/janus.jcfg || true
		;;
	ppc64le)
		deploy_file "$TMP_DIR_PATH"/signaling/janus_powerpc64le.jcfg /etc/janus/janus.jcfg || true
		;;
	*)
		deploy_file "$TMP_DIR_PATH"/signaling/janus.jcfg /etc/janus/janus.jcfg || true
		;;
	esac
	deploy_file "$TMP_DIR_PATH"/signaling/janus.transport.http.jcfg /etc/janus/janus.transport.http.jcfg || true
	deploy_file "$TMP_DIR_PATH"/signaling/janus.transport.websockets.jcfg /etc/janus/janus.transport.websockets.jcfg || true

	deploy_file "$TMP_DIR_PATH"/signaling/signaling-server.conf /etc/nextcloud-spreed-signaling/server.conf || true

	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		deploy_file "$TMP_DIR_PATH"/signaling/turnserver.conf /etc/turnserver.conf || true
		deploy_file "$TMP_DIR_PATH"/signaling/coturn.service /etc/systemd/system/coturn.service || true
	fi
}

# arg: $1 is secret file path
function signaling_write_secrets_to_file() {
	if is_dry_run; then
		return 0
	fi

	echo -e "=== Signaling / Nextcloud Talk ===" >>$1
	echo -e "Janus API key: $SIGNALING_JANUS_API_KEY" >>$1
	echo -e "Hash key:      $SIGNALING_HASH_KEY" >>$1
	echo -e "Block key:     $SIGNALING_BLOCK_KEY" >>$1
	echo -e "" >>$1
	echo -e "Allowed Nextcloud Servers:" >>$1
	echo -e "$(printf '\t- https://%s\n' "${NEXTCLOUD_SERVER_FQDNS[@]}")" >>$1
	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		echo -e "STUN server = $SERVER_FQDN:5349" >>$1
		echo -e "TURN server:" >>$1
		echo -e " - 'turn and turns'" >>$1
		echo -e " - $SERVER_FQDN:5349" >>$1
		echo -e " - $SIGNALING_TURN_STATIC_AUTH_SECRET" >>$1
		echo -e " - 'udp & tcp'" >>$1
	else
		echo -e "Local coturn (TURN/STUN): not installed — configure STUN/TURN in Nextcloud Talk admin if clients need relay." >>$1
	fi
	echo -e "High-performance backend:" >>$1
	echo -e " - https://$SERVER_FQDN/standalone-signaling" >>$1

	for NC_SERVER in "${NEXTCLOUD_SERVER_FQDNS[@]}"; do
		NC_SERVER_UNDERSCORE=$(echo "$NC_SERVER" | sed "s/\./_/g")
		echo -e " - $NC_SERVER\t-> ${SIGNALING_NC_SERVER_SECRETS["$NC_SERVER_UNDERSCORE"]}" >>$1
	done
}

function signaling_print_info() {
	local svc_list="janus, nats-server, nextcloud-spreed-signaling"
	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		svc_list="coturn, $svc_list"
	fi
	log "Installed: $svc_list." \
		"\nTo finish setup, log into each Nextcloud as admin, open the Talk app," \
		"\nthen Settings → Administration → Talk and enter the values below.\n" \
		"$(for NC_SERVER in "${NEXTCLOUD_SERVER_FQDNS[@]}"; do printf '\t- %shttps://%s%s\n' "${cyan}" "$NC_SERVER" "${blue}"; done)\n"

	if [ "$SHOULD_INSTALL_COTURN" = true ]; then
		log "STUN server = ${cyan}$SERVER_FQDN:5349"
		log "TURN server:"
		log " - '${cyan}turn and turns${blue}'"
		log " - ${cyan}turnserver+port${blue}: ${cyan}$SERVER_FQDN:5349"
		echo -e " - secret: ${cyan}$SIGNALING_TURN_STATIC_AUTH_SECRET"
		log " - '${cyan}udp & tcp${blue}'"
	else
		log "${yellow}Local coturn was not installed.${normal} If users are behind strict NAT," \
			"\nadd STUN/TURN servers under Talk settings (or re-run with local TURN enabled)."
	fi
	log "High-performance backend:"
	log " - ${cyan}https://$SERVER_FQDN/standalone-signaling"

	for NC_SERVER in "${NEXTCLOUD_SERVER_FQDNS[@]}"; do
		NC_SERVER_UNDERSCORE=$(echo "$NC_SERVER" | sed "s/\./_/g")
		echo -e " - ${cyan}$NC_SERVER${blue}\t-> ${cyan}${SIGNALING_NC_SERVER_SECRETS["$NC_SERVER_UNDERSCORE"]}"
	done
}
