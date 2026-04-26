#!/bin/bash

# firewalld (RHEL / Rocky / AlmaLinux / Oracle Linux and similar)

function install_firewalld() {
	announce_installation "Installing firewalld"
	log "Installing firewalld…"

	firewalld_step1
	firewalld_step2

	log "firewalld configuration completed."
}

function dnf_install_firewalld() {
	local args="-y"
	if [ "$UNATTENDED_INSTALL" == true ]; then
		args="-y -q"
	fi
	is_dry_run || dnf install $args firewalld 2>&1 | tee -a "$LOGFILE_PATH"
}

function firewalld_step1() {
	log "\n${green}Step 1: Install firewalld${normal}"
	is_dry_run || dnf_install_firewalld
}

function firewalld_step2() {
	log "\n${green}Step 2: Configure firewall zones${normal}"

	local _cmdprefix=""
	is_dry_run && _cmdprefix="log " || true

	# Ensure service is running for runtime commands
	is_dry_run || systemctl enable --now firewalld 2>&1 | tee -a "$LOGFILE_PATH" || true

	${_cmdprefix}firewall-cmd --permanent --set-default-zone=public 2>&1 | tee -a "$LOGFILE_PATH" || true

	if [ "$DISABLE_SSH_SERVER" != true ]; then
		${_cmdprefix}firewall-cmd --permanent --add-service=ssh 2>&1 | tee -a "$LOGFILE_PATH" || true
	fi

	if [ "$SHOULD_INSTALL_NGINX" = true ]; then
		${_cmdprefix}firewall-cmd --permanent --add-service=http 2>&1 | tee -a "$LOGFILE_PATH" || true
		${_cmdprefix}firewall-cmd --permanent --add-service=https 2>&1 | tee -a "$LOGFILE_PATH" || true
	fi

	if [ "$SHOULD_INSTALL_SIGNALING" = true ] && [ "$SHOULD_INSTALL_COTURN" = true ]; then
		${_cmdprefix}firewall-cmd --permanent --add-port=5349/tcp 2>&1 | tee -a "$LOGFILE_PATH" || true
		${_cmdprefix}firewall-cmd --permanent --add-port=5349/udp 2>&1 | tee -a "$LOGFILE_PATH" || true
	fi

	${_cmdprefix}firewall-cmd --reload 2>&1 | tee -a "$LOGFILE_PATH" || true
}
