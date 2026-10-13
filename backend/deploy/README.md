# Same-server setup reference

> **Disclaimer:** This course adaptation and its backend are a vibe-coded project developed with AI assistance.

The complete, simple [same-server setup](../README.md#run-both-services-on-the-same-server)
is in the main backend README. It uses Next.js, Puma, SQLite, two systemd services,
and Caddy for automatic HTTPS. Follow that guide first.

This file covers one-time proxy installation, using an existing Nginx server, and
administrative commands on the server.

## Install Caddy on Debian or Ubuntu

Skip this section if Caddy is already installed. These commands use the
[official stable package repository](https://caddyserver.com/docs/install#debian-ubuntu-raspbian)
and install its `caddy` systemd service:

```sh
sudo apt install --yes debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

Return to [step 5 of the setup](../README.md#run-both-services-on-the-same-server)
to add your domain and proxy routes. A reusable [Caddyfile example](Caddyfile.example)
is included. Your DNS must point to the server and ports 80/443 must be reachable
for [automatic HTTPS](https://caddyserver.com/docs/automatic-https).

## If your server already uses Nginx

Keep your existing HTTPS proxy and frontend route. Follow steps 1–4 and 6–7 of the
[main setup](../README.md#run-both-services-on-the-same-server), skipping the Caddy step.
Use your existing domain for the frontend build and backend environment values.
When checking services, use `nginx` in place of `caddy`.

Add this location to the existing HTTPS `server` block for your domain:

```nginx
location ^~ /v1/ {
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_cache off;
    access_log off;
}
```

Keep `proxy_pass` without a trailing slash: the backend needs the `/v1/` prefix.
The existing frontend location should forward to Next.js on `127.0.0.1:3000`:

```nginx
location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
}
```

Update the existing location if necessary; do not add a duplicate. Check and reload:

```sh
sudo nginx -t
sudo systemctl reload nginx
```

The [complete Nginx example](nginx.conf.example) is also available. It assumes an
existing valid TLS certificate; keep your server's own domain and certificate paths.
Only one proxy needs to serve the website on ports 80/443.

## Run administrative commands on the server

Open a shell as the service user and load the same configuration as the backend:

```sh
sudo -u satoshi /bin/sh
cd /srv/saving-satoshi/backend
set -a
. /etc/saving-satoshi/backend.env
set +a
bundle exec ruby bin/admin list
```

The environment file selects `/var/lib/saving-satoshi/course.sqlite3`.
Keep it loaded when creating/importing accounts, exporting progress, or making a
backup. See the [account commands](../README.md#manage-accounts),
[CSV format](../README.md#import-accounts-from-csv), and
[backup instructions](../README.md#back-up-and-restore).

## Runtime paths

The main setup assumes system-wide Ruby/Bundler, Node, and Yarn installations that
the `satoshi` user can run. A runtime installed only in your personal home directory
is not automatically available to that user.

If using a version manager for the service user, set the absolute executable paths
and its runtime `PATH` in each systemd unit. Keep code at `/srv/saving-satoshi` and
ensure the same user can install dependencies, build the frontend, and start both
services. Service errors are available with `journalctl -u saving-satoshi-backend`
and `journalctl -u saving-satoshi-frontend`.
