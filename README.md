# Nextcloud Talk HPB setup (Enterprise Linux)

Fork of [nextcloud-high-performance-backend-setup](https://github.com/sunweaver/nextcloud-high-performance-backend-setup) focused on **Fedora and RHEL-family** systems (RHEL, Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream) and **Nextcloud Talk** high-performance backend only.

## What it installs

- **Talk high-performance backend**: `nextcloud-spreed-signaling` (built from upstream Git), **NATS**, **Janus** (RPM from your enabled repos, typically EPEL).
- **Optional** **coturn** for local TURN/STUN (`SHOULD_INSTALL_COTURN` or interactive checklist). If you skip it, configure STUN/TURN under Nextcloud **Administration → Talk**.
- **nginx** reverse proxy (config in `/etc/nginx/conf.d/`), **Certbot** with the nginx plugin, and **firewalld** (HTTP/HTTPS; coturn TLS ports when coturn is enabled).

### Behind Traefik (or another reverse proxy)

Set **`BEHIND_EXISTING_REVERSE_PROXY=true`** in `settings.sh` (or tick the matching option in the interactive checklist). The script then **skips nginx and Certbot** on this host and still installs **signaling, NATS, Janus**, and optionally **coturn**.

After a successful run, check **`tmp/reverse-proxy/traefik-dynamic.<your-SERVER_FQDN>.yml`** for a Traefik v3 file-provider fragment with **Host** and **PathPrefix(`/standalone-signaling`)** rules pointing at the signaling HTTP listener.

- **Same host as Traefik:** keep **`SIGNALING_HTTP_LISTEN`** at the default `127.0.0.1:8080` and point the YAML `servers[].url` at `http://127.0.0.1:8080`.
- **Traefik on another machine:** set **`SIGNALING_HTTP_LISTEN`** to something reachable (e.g. `0.0.0.0:8080` on a private interface), restrict access in **firewalld** or network ACLs, and set the YAML backend URL to `http://<this-host-LAN-IP>:8080`.

**coturn TLS** still needs certificate material on this host if you enable it; sync or reference the same certs your proxy uses, or configure paths in `settings.sh` before running.

## Requirements

- Run as **root** on a registered and fully updated system (`dnf update`).
- **EPEL** is installed automatically where possible; **Janus** must be available from your repositories (EPEL on many EL versions). If `dnf install janus` fails, enable extra repos (e.g. RPM Fusion) or install a compatible `janus` package, then re-run.
- DNS **A/AAAA** records for `SERVER_FQDN` before requesting Let’s Encrypt certificates.

## Usage

```bash
sudo ./setup-nextcloud-hpb.sh
# or unattended-style:
sudo ./setup-nextcloud-hpb.sh ./settings.sh
```

See `settings.sh` for variables. `Makefile` target `install` runs the same script.

## License

Same as upstream (see `LICENSE` / `AUTHORS`).
