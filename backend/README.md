# Saving Satoshi course backend

> **Disclaimer:** This backend is a vibe-coded project developed with AI assistance.

This small Ruby/Sinatra service stores student accounts and learning progress in
SQLite. The Next.js frontend runs separately. Code execution uses the public
Saving Satoshi runner.

Choose your setup:

- [Try the demo locally](demo/README.md): sample accounts and progress.
- [Start a local course database](#start-a-local-course-database).
- [Run frontend and backend on one server](#run-both-services-on-the-same-server): full setup below.
- [User management API comparison](../docs/user-management-api.md): every original account-related route and its course equivalent.

## Start a local course database

You need Ruby 3.2 or later, Bundler, Node 26.11.1 (see `.nvmrc`), and Yarn 1.
Use two terminal windows. Replace `/path/to/saving-satoshi` with your project folder:
the folder containing `package.json` and `backend/`.

1. **Prepare the backend in terminal 1.**

   ```sh
   cd /path/to/saving-satoshi/backend
   bundle config set --local path vendor/bundle
   bundle install
   DATABASE_PATH=./var/course.sqlite3 bundle exec ruby bin/admin init
   ```

   Bundler installs gems under `backend/vendor/bundle`, where your user can write.
   Run the `bundle config` command once in `backend/`; its local configuration and
   installed gems are ignored by Git. The database command creates the file if it
   is missing and keeps any existing accounts.

2. **Start the backend in the same terminal.**

   ```sh
   DATABASE_PATH=./var/course.sqlite3 bundle exec puma -C puma.rb config.ru
   ```

   The API runs at `http://localhost:8000`. Keep this terminal open.

3. **Start the frontend in terminal 2.**

   ```sh
   cd /path/to/saving-satoshi
   yarn install --frozen-lockfile
   NEXT_PUBLIC_API_ENDPOINT=http://localhost:8000 NEXT_PUBLIC_WS_ENDPOINT=wss://api.savingsatoshi.com yarn dev
   ```

   These settings select the local REST API and the public runner. They override
   existing frontend environment values for this command. No `.env.local` edit is
   needed. Code execution needs an internet connection.

4. **Open the frontend and create or sign in to an account.**

   Open `http://localhost:3000/en/chapters`, then the profile at the top right.
   For a quick test, use the existing **Create account** flow. For named student
   accounts, use the CLI or CSV import below.

   Students sign in with a **64-character hexadecimal login key** in the
   **private key** field. The username is an administrative label and is not entered
   at login. Give each student their own random key; never use a real wallet key.
   Self-created accounts get names such as `self-<random ID>`.

5. **Stop or restart the services.**

   Press **Ctrl+C** in each terminal to stop. Accounts and progress remain in
   `backend/var/course.sqlite3`. Next time, repeat the start commands in steps 2 and 3.

To prevent self-registration, prefix the backend start command with
`ALLOW_REGISTRATION=false`. The original frontend registration button stays visible,
but the backend rejects registration requests.

## Run both services on the same server

Use one Linux server, one domain, SQLite, two small systemd services, and Caddy
for HTTPS. Caddy automatically obtains and renews certificates
([how automatic HTTPS works](https://caddyserver.com/docs/automatic-https)).

```text
Browser -> https://satoshi.example.edu -> Caddy
                                         /v1/* -> Puma    127.0.0.1:8000 -> SQLite
                                         /*    -> Next.js 127.0.0.1:3000
Browser -> public Saving Satoshi runner
```

**Before starting:** log in to your Debian/Ubuntu server over SSH. You need sudo, systemd,
Ruby/Bundler, Node as specified in `.nvmrc`, and Yarn 1. Ruby, Bundler, Node, and
Yarn must be installed system-wide and available to the `satoshi` service user.
Node 26 is currently a Current release; for a long-lived production server,
consider Node 24 LTS after checking the frontend build with that version.
The domain's DNS must point to this server, and ports **80 and 443** must be reachable.
The application ports 3000 and 8000 stay local.

Replace **`satoshi.example.edu`** with your domain in the examples below.
These steps use `/srv/saving-satoshi` for code and `/var/lib/saving-satoshi` for data.
If your frontend already uses Nginx, follow steps 1–4 and 6–7 below and use the
[existing Nginx proxy instructions](deploy/README.md#if-your-server-already-uses-nginx)
for step 5.

1. **Put the project on the server and prepare its folders.**

   Upload and extract the complete project so that
   `/srv/saving-satoshi/package.json` and `/srv/saving-satoshi/backend/` exist.
   For example, after uploading the supplied ZIP to `/tmp/`:

   ```sh
   sudo unzip /tmp/saving-satoshi-student-backend.zip -d /srv
   sudo useradd --system --user-group --home-dir /srv/saving-satoshi --shell /usr/sbin/nologin satoshi
   sudo chown -R satoshi:satoshi /srv/saving-satoshi
   sudo install -d -o satoshi -g satoshi -m 0700 /var/lib/saving-satoshi
   sudo install -d -o root -g satoshi -m 0750 /etc/saving-satoshi
   ```

   Skip `useradd` if that account already exists. Keep the database on a local disk.

2. **Install and configure the backend.**

   ```sh
   sudo -u satoshi sh -c 'cd /srv/saving-satoshi/backend && bundle config set --local path vendor/bundle && bundle install'
   sudo install -o root -g satoshi -m 0640 /srv/saving-satoshi/backend/deploy/backend.env.example /etc/saving-satoshi/backend.env
   sudo nano /etc/saving-satoshi/backend.env
   ```

   In this file, change these two values to your domain:

   ```dotenv
   ALLOWED_HOSTS=satoshi.example.edu,localhost,127.0.0.1
   ALLOWED_ORIGINS=https://satoshi.example.edu
   ```

   Keep `DATABASE_PATH=/var/lib/saving-satoshi/course.sqlite3` and
   `BIND=tcp://127.0.0.1:8000`. Optionally set `ALLOW_REGISTRATION=false` if you
   want only CLI-created accounts. Then initialize the database:

   ```sh
   sudo -u satoshi sh -c 'cd /srv/saving-satoshi/backend && set -a && . /etc/saving-satoshi/backend.env && set +a && bundle exec ruby bin/admin init'
   ```

3. **Install and build the frontend.**

   Change the domain in this command before running it:

   ```sh
   sudo -u satoshi sh -c 'cd /srv/saving-satoshi && yarn install --frozen-lockfile && NEXT_PUBLIC_API_ENDPOINT=https://satoshi.example.edu NEXT_PUBLIC_WS_ENDPOINT=wss://api.savingsatoshi.com yarn build'
   ```

   The REST URL is embedded into the frontend during this build. The explicit
   values override existing `.env.local` settings. Keep this command with your
   domain for future rebuilds. The public runner URL stays as shown.

4. **Keep both services running after logout and reboot.**

   Check the executable paths available to the service user:

   ```sh
   sudo -u satoshi sh -c 'command -v bundle'
   sudo -u satoshi sh -c 'command -v node'
   ```

   Install the two supplied service files:

   ```sh
   sudo install -m 0644 /srv/saving-satoshi/backend/deploy/saving-satoshi-backend.service /etc/systemd/system/
   sudo install -m 0644 /srv/saving-satoshi/backend/deploy/saving-satoshi-frontend.service /etc/systemd/system/
   sudo nano /etc/systemd/system/saving-satoshi-backend.service
   sudo nano /etc/systemd/system/saving-satoshi-frontend.service
   ```

   Set the first path in each `ExecStart=` line to the corresponding path printed
   above: `bundle` for the backend, `node` for the frontend. Keep the arguments.
   Then start the services:

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now saving-satoshi-backend saving-satoshi-frontend
   ```

5. **Publish the website with HTTPS.**

   Install Caddy if it is missing; the [one-time package installation](deploy/README.md#install-caddy-on-debian-or-ubuntu)
   sets up its systemd service. Open its configuration:

   ```sh
   sudo nano /etc/caddy/Caddyfile
   ```

   Add this site block with your domain. Keep any other sites already in the file:

   ```caddyfile
   satoshi.example.edu {
       handle /v1/* {
           reverse_proxy 127.0.0.1:8000
       }
       handle {
           reverse_proxy 127.0.0.1:3000
       }
   }
   ```

   `/v1/` stays in the request path so the backend receives its existing API URLs.
   Validate and reload:

   ```sh
   sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   sudo systemctl enable --now caddy
   sudo systemctl reload caddy
   ```

6. **Check the website and API.**

   ```sh
   curl --fail http://127.0.0.1:8000/health
   curl --fail https://satoshi.example.edu/v1/features
   ```

   Open `https://satoshi.example.edu/en/chapters` in your browser and sign in with
   a course account. Create or import accounts using the
   [server administration commands](deploy/README.md#run-administrative-commands-on-the-server).

7. **Restart or inspect the services when needed.**

   ```sh
   sudo systemctl restart saving-satoshi-backend saving-satoshi-frontend
   sudo systemctl status --no-pager saving-satoshi-backend saving-satoshi-frontend caddy
   sudo journalctl -u saving-satoshi-backend -u saving-satoshi-frontend --no-pager -n 50
   ```

   Back up SQLite with the [backup command](#back-up-and-restore). For updates,
   rebuild with the same command and domain from step 3, then restart both services.
   The database remains outside the project folder.

## Manage accounts

Open another terminal in `backend/` and select the **same database** as the running
backend. For the local course setup:

```sh
cd /path/to/saving-satoshi/backend
export DATABASE_PATH=./var/course.sqlite3
```

For the demo, use `export DATABASE_PATH=./var/demo.sqlite3` instead. On the server,
[load the service environment](deploy/README.md#run-administrative-commands-on-the-server).

| Action                             | Command                                                |
| ---------------------------------- | ------------------------------------------------------ |
| Create an account                  | `bundle exec ruby bin/admin create student001`         |
| List accounts                      | `bundle exec ruby bin/admin list`                      |
| Deactivate an account              | `bundle exec ruby bin/admin deactivate student001`     |
| Reactivate an account              | `bundle exec ruby bin/admin activate student001`       |
| Reset a login key                  | `bundle exec ruby bin/admin reset-password student001` |
| Delete an account and its progress | `bundle exec ruby bin/admin delete student001`         |

`create` and `reset-password` ask twice for a new login key, hiding your input.
To generate one, run `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`, then copy
it into the prompts. Keep it private. Do not put keys in command arguments or
shell history. For scripted input, `--password-stdin` reads one line from stdin.
Deactivation and password resets revoke existing sessions.

## Import accounts from CSV

The [demo CSV](demo/accounts.csv) shows the exact format. Use **UTF-8**, a **comma**
separator, and the header **`username,password`**. Include one account per row:

```csv
username,password
student001,5a492ffc15c7885d454956913d10640a452a30a17984d39bec9a0721bc951da2
student002,c492c58d1713945ebfa5ad8562a37997f0c59a9b624166cd7400572235682df0
```

These published keys are examples only. Generate fresh keys for real students.

- **`username`:** 1–64 ASCII characters. Start with a letter or digit; remaining
  characters may also include `.`, `_`, and `-`. No spaces or umlauts. Names are
  converted to lowercase and must be unique.
- **`password`:** a different random 64-character hexadecimal key for each account.
  Use `0–9` and `a–f`/`A–F`, without `0x`, spaces, or hyphens. It must be a valid,
  nonzero secp256k1 key. Ordinary text passwords are not supported. Students enter
  this value in the frontend's **private key** field.
- Include 1–2000 accounts. Do not add extra columns, comments, or blank rows.
  Both LF and CRLF line endings work; a UTF-8 BOM is accepted.
- In Excel, choose comma-separated UTF-8 CSV and keep keys as text.
  Semicolon-separated CSV is rejected.

With the database selected as above, import the file:

```sh
bundle exec ruby bin/admin import-csv /private/course-users.csv
bundle exec ruby bin/admin list
```

Replace `/private/course-users.csv` with your file path. Import creates active
accounts with no saved progress. Invalid rows, duplicate names or keys, and existing
accounts cancel the entire import. Import never silently resets passwords.
SQLite stores bcrypt hashes and a lookup hash; it does not store plaintext keys.

### Generate a CSV for a whole class

The following creates 150 accounts, `student001` through `student150`, with fresh
random keys. Replace `/private/course-users.csv` with a new file path in an existing
private folder outside the repository. Change `150` to the number of students:

```sh
ruby -rcsv -rsecurerandom - 150 /private/course-users.csv <<'RUBY'
count = Integer(ARGV.fetch(0))
raise 'Count must be 1–2000' unless count.between?(1, 2000)
File.open(ARGV.fetch(1), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  csv = CSV.new(file)
  csv << %w[username password]
  count.times { |i| csv << [format('student%03d', i + 1), SecureRandom.hex(32)] }
end
RUBY
bundle exec ruby bin/admin import-csv /private/course-users.csv
```

Existing files are not overwritten. You can edit the usernames before importing.
Give each student only their own key. Keep the CSV private; do not commit it to the
repository or share it with the class.

## Export progress

Run from `backend/` with the same `DATABASE_PATH` selected:

```sh
bundle exec ruby bin/admin export-progress
bundle exec ruby bin/admin export-progress ./var/progress.csv
```

The first command prints CSV in the terminal. The second writes a **new** file;
choose another filename if it already exists. The export includes username,
active status, current chapter and lesson, completed and total lessons, completion
percentage, last progress update, and last login. Times are UTC.

Intro and outro pages count as lessons. The count uses enabled chapters and the
selected difficulty; accounts without saved progress have no lesson total yet.
Progress is reported by the frontend, so use it to monitor learning rather than
as tamper-resistant grading.

## Back up and restore

From `backend/`, with the same database selected:

```sh
bundle exec ruby bin/admin backup ./var/course-backup.sqlite3
```

Choose a new destination filename. This command safely backs up a running database,
including committed changes in SQLite's WAL. Do not copy only the live `.sqlite3`
file. Keep backups private and copy them to a separate location.

To restore:

1. Stop the backend.
2. Move the current database and any matching `-wal` and `-shm` files aside.
3. Copy the backup to the configured database path. Set its owner to the backend
   service user and its file permissions to `0600`.
4. Restart the backend. Frontend sessions may need a new login. A backup can contain
   old sessions; remove them before restarting if needed:
   `sqlite3 "$DATABASE_PATH" 'DELETE FROM sessions;'`.

## Configuration reference

Backend settings come from environment variables; `backend/.env.example` is **not
loaded automatically**. Set them in the shell or the service environment file.

| Variable              | Default                      | Purpose                                                                 |
| --------------------- | ---------------------------- | ----------------------------------------------------------------------- |
| `DATABASE_PATH`       | `backend/var/course.sqlite3` | SQLite file; explicit relative paths resolve from the working directory |
| `BIND`                | `tcp://127.0.0.1:8000`       | Backend address                                                         |
| `ALLOWED_ORIGINS`     | `http://localhost:3000`      | Allowed frontend origins, comma-separated, no trailing slash            |
| `ALLOWED_HOSTS`       | `localhost,127.0.0.1,::1`    | Allowed HTTP hostnames, without scheme or port                          |
| `ALLOW_REGISTRATION`  | `true`                       | Allow the existing frontend signup flow                                 |
| `SESSION_TTL_SECONDS` | `28800`                      | Session lifetime: eight hours                                           |
| `COURSE_CHAPTER_IDS`  | `1,2,3,8,9,10`               | Enabled chapters and progress export scope                              |

Frontend settings:

```dotenv
NEXT_PUBLIC_API_ENDPOINT=http://localhost:8000
NEXT_PUBLIC_WS_ENDPOINT=wss://api.savingsatoshi.com
```

For persistent local settings, put these in `.env.local` in the project root.
Restart `yarn dev` after changing them. Production settings are embedded during
`yarn build`; see the server guide. Use HTTPS for the public website. The frontend
keeps credentials in tab-local session storage; logout clears them.

## Run tests

From the project folder:

```sh
cd backend
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require_relative f }'
cd ..
yarn test
yarn tsc --noEmit
yarn build
```

Optional browser tests need an installed Playwright browser:

```sh
yarn playwright install chromium
yarn test:student-e2e
```

Browser tests use temporary data and ports 8001/3001. For endpoints, database schema,
and the minimal frontend changes, see the [implementation analysis](../docs/student-backend-analysis.md)
and [user management API comparison](../docs/user-management-api.md).
