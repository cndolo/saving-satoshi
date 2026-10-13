# Try Saving Satoshi with the demo

> **Disclaimer:** This backend and its demo are part of a vibe-coded project developed with AI assistance.

Use two terminal windows to start the backend and frontend on your computer.
The demo contains four synthetic accounts and sample progress. Its login keys are
public test credentials: use this database only for local testing.

You need Ruby 3.2 or later, Bundler, Node 26.11.1 (see `.nvmrc`), and Yarn 1.
Replace `/path/to/saving-satoshi` with the folder containing `package.json` and
`backend/`.

## 1. Prepare the backend — terminal 1

```sh
cd /path/to/saving-satoshi/backend
bundle config set --local path vendor/bundle
bundle install
test -f var/demo.sqlite3 || bundle exec ruby bin/create-demo
```

Bundler installs gems in `backend/vendor/bundle`, avoiding system gem write
permissions. Run the `bundle config` command once in `backend/`.
This creates `backend/var/demo.sqlite3` with the demo accounts and their progress
only if the file is missing. If it already exists, your previous demo data is kept.
You do not need to import the CSV separately.

## 2. Start the backend — same terminal

```sh
DATABASE_PATH=./var/demo.sqlite3 bundle exec puma -C puma.rb config.ru
```

The API runs at `http://localhost:8000`. Keep this terminal open.
Always use this `DATABASE_PATH` when starting or administering the demo.

## 3. Start the frontend — terminal 2

```sh
cd /path/to/saving-satoshi
yarn install --frozen-lockfile
NEXT_PUBLIC_API_ENDPOINT=http://localhost:8000 NEXT_PUBLIC_WS_ENDPOINT=wss://api.savingsatoshi.com yarn dev
```

The frontend uses your local backend for accounts and progress. Code execution
still uses the public runner and needs an internet connection. These values
override existing frontend settings for this command; no `.env.local` edit is needed.

## 4. Sign in in the browser

Open `http://localhost:3000/en/chapters`. Open the profile at the top right, then
sign in. In the **private key** field, paste this full key for `demo-lesson`:

```text
2222222222222222222222222222222222222222222222222222222222222222
```

Confirm the login, then choose **Take me to where I left off**. With fresh demo
data, this opens `/en/chapters/chapter-1/intro-2`, **Satoshi's holocat**.
The username is an administrative label; it is not entered at login.

## 5. Find the saved progress

`demo-lesson` has completed the first **intro page**, **Miner protest** (`CH1INT1`).
It has not completed the first Genesis challenge or the whole chapter.
Saving Satoshi counts story intro pages as lessons, which is why the export says
one completed lesson.

To see the completion mark:

1. Open `http://localhost:3000/en/chapters` while signed in.
2. Under **Chapter 1**, select **Challenges**.
3. Under **Intro**, **Miner protest** has a checkmark. **Satoshi's holocat** is
   available but still incomplete in a fresh demo.

The numbered navigation tab for the whole Intro group only gets a checkmark after
**both** intro pages are complete. This is why a single completed intro page can
be easy to miss.

Now continue learning, complete a page using **Continue**, and reload. Your new
progress should still be there. Existing working demo databases retain your changes,
so their progress may be further along than the initial examples below.

## 6. Try the other accounts

Sign out through the profile before switching accounts. Copy the **entire** value
from the `password` column in [accounts.csv](accounts.csv) into **private key**.

| Account         | Login key             | Initial state in a fresh demo                                 |
| --------------- | --------------------- | ------------------------------------------------------------- |
| `demo-new`      | `1` repeated 64 times | No saved progress; starts at the first intro page             |
| `demo-lesson`   | `2` repeated 64 times | First intro page complete; continues at the second intro page |
| `demo-chapter`  | `3` repeated 64 times | All 11 pages of chapter 1 complete; continues at chapter 2    |
| `demo-disabled` | `4` repeated 64 times | Disabled; login is rejected                                   |

Each account has its own progress. The disabled account's login returns HTTP 401;
the original sign-in dialog stays open. The frontend's **Create account** flow also
works and creates additional accounts in this working demo database.

## 7. Stop and restart

Press **Ctrl+C** in both terminal windows. The working database keeps your accounts
and progress. To continue later, repeat the start commands in steps 2 and 3.

## Check the administrative export

In another terminal, select the same working demo database:

```sh
cd /path/to/saving-satoshi/backend
DATABASE_PATH=./var/demo.sqlite3 bundle exec ruby bin/admin list
DATABASE_PATH=./var/demo.sqlite3 bundle exec ruby bin/admin export-progress
```

The second command prints CSV. Before further learning, `demo-lesson` has
`current_lesson=CH1INT2` and `completed_lessons=1`; `demo-chapter` has `CH2INT1` and
11 completed lessons. Login and progress timestamps update as you use the demo.
See [student administration](../README.md#manage-accounts) for account changes,
CSV export to a file, and backups.

## Start again with fresh demo data

Sign out and stop the backend with **Ctrl+C**. Create a new database and start it:

```sh
cd /path/to/saving-satoshi/backend
bundle exec ruby bin/create-demo ./var/demo-reset.sqlite3
DATABASE_PATH=./var/demo-reset.sqlite3 bundle exec puma -C puma.rb config.ru
```

Use an unused filename each time: the generator refuses to overwrite any file or
symlink. The previous demo database remains available. Sign in again in the frontend;
sessions from the previous database are not valid in the fresh one.

## Included test files

- [accounts.csv](accounts.csv): the four accounts in `username,password` format.
- `course-demo.sqlite3`: a prepared database with the same initial accounts and
  progress. Keep this fixture unchanged; use `var/demo.sqlite3` for your tests.
- [scenarios.json](scenarios.json): the initial progress, status, and sample timestamps.
- [progress-export.csv](progress-export.csv): an export of the initial demo data.

**CSV import alone does not include progress or disabled status.** To test only the
import, use a separate new database:

```sh
cd /path/to/saving-satoshi/backend
DATABASE_PATH=./var/csv-import-demo.sqlite3 bundle exec ruby bin/admin init
DATABASE_PATH=./var/csv-import-demo.sqlite3 bundle exec ruby bin/admin import-csv ./demo/accounts.csv
DATABASE_PATH=./var/csv-import-demo.sqlite3 bundle exec ruby bin/admin list
```

This creates all four accounts as active, with no saved progress. Use the generator
in step 1 for the complete demo scenario. Working databases under `var/` are excluded
from version control; the regular course database is separate from the demo.
