#!/bin/bash

# Automatic security updates via dnf-automatic (optional on Enterprise Linux)

function install_dnf_automatic() {
	announce_installation "Installing dnf-automatic"
	log "Installing dnf-automatic…"

	dnf_automatic_step1
	dnf_automatic_step2

	log "dnf-automatic configuration completed."
}

function dnf_automatic_step1() {
	log "\n${green}Step 1: Install dnf-automatic${normal}"
	local args="-y"
	if [ "$UNATTENDED_INSTALL" == true ]; then
		args="-y -q"
	fi
	is_dry_run || dnf install $args dnf-automatic 2>&1 | tee -a "$LOGFILE_PATH"
}

function dnf_automatic_step2() {
	log "\n${green}Step 2: Enable security update timer${normal}"
	# Apply updates from configured sources (see /etc/dnf/automatic.conf)
	is_dry_run || sed -i 's/^apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
	is_dry_run || sed -i 's/^# apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
	is_dry_run || systemctl enable --now dnf-automatic.timer 2>&1 | tee -a "$LOGFILE_PATH" || true
}
