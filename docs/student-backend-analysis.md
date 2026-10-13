# Course version analysis and minimal integration

Frontend baseline before the backend work: commit `0e11d91017d2b4fa47745f4f4ad95eec46f1c6d5`.

## Existing API

`utils/fetch.ts` adds bearer tokens. `utils/url.ts` already uses
`NEXT_PUBLIC_API_ENDPOINT`; without configuration, it defaults to the public REST API.
`api/auth` uses `POST /v1/auth/login` with `{private_key}`, `POST /v1/auth/register`
with `{private_key, avatar}`, `GET /v1/auth/session`, and `POST /v1/auth/logout`.
The existing dialogs generate a random secp256k1 key, let users back it up, and use
it as the login password.

`GET/PUT /v1/progress` transfers `{progress_state: CourseProgress}` containing
`chapters`, `currentChapter`, `currentLesson`, lessons, difficulty variants, and
completion flags. `state/progress` merges saved snapshots with the defaults.
The original browser-wide local storage fallback can import another account's or
guest progress when switching accounts and overwrite server data after a load failure.

`GET /v1/data/:lesson_id` and `PUT /v1/data` store answers and Base64-encoded code for
scripting challenges that build on previous lessons. The backend treats these as
inert progress data. The existing `account_id` in write requests is checked against
the session; the server never treats it as authorization.
`GET /v1/features` enables visible chapters through `chapter_N_enabled = 1`.

The runner in `ui/lesson/ScriptingChallenge/Runner/index.tsx` connects directly to
`NEXT_PUBLIC_WS_ENDPOINT` (default: `wss://api.savingsatoshi.com`). Its code and
protocol remain unchanged; the REST API and runner can already be configured separately.

## Frontend changes

Sign-in, account, and registration dialogs, text, the account type, and chapter-end
screens remain as they were in the original project. The backend implements their
existing key-based API. CLI/CSV accounts also have an administrative username; their
password is the random 64-character login key. Self-registration is enabled by
default and can be blocked with `ALLOW_REGISTRATION=false`.

- `api/auth/{login,getSession,logout}.ts`, `config/keys.ts`, `utils/fetch.ts`: store
  tokens per tab, handle HTTP errors, and keep the key locally for the original
  account dialog. The backend neither stores nor returns plaintext keys.
- `api/auth/register.ts`: transfer the current guest progress once when creating a
  new account; existing course accounts remain separate.
- `state/AuthFunctions.ts`: reset account data and drafts on logout; do not import
  another account's progress on login.
- `api/progress/{getProgress,setProgress}.ts`, `state/progress/{actions,atoms}.ts`:
  load authenticated account progress exclusively from the server; avoid guest
  fallbacks and writes of default state after errors; write snapshots sequentially.
- `hooks/usePrevLessonLanguage.ts`, `ui/lesson/ScriptingChallenge/index.tsx`: ignore
  stale answer data and store local code drafts separately for each account.
- `components/ProgressSyncStatus.tsx` and two lines in `components/Layout.tsx`:
  make saving failures visible and provide a retry action.
- `content/lessons/chapter-4/public-key-3.tsx`: use a fixed public teaching key as
  exercise input, preventing the login key from being sent to the public runner.
- `.env.example`: use the course REST endpoint and the unchanged public runner.

`api/data/setData.ts`, `utils/url.ts`, the dialogs, and all runner files require no
changes. No frontend dependencies are added.

## Backend, authentication, and schema

One Ruby/Sinatra process, SQLite, and bcrypt with cost factor 12. The login key is
normalized to lowercase and hashed. A unique SHA-256 lookup value identifies the
account without performing 150 bcrypt checks per login; this requires random
256-bit keys. Do not use short, user-chosen passwords or keys derived from them.

Login returns a random 256-bit bearer token; SQLite stores only its SHA-256 hash.
Sessions expire after eight hours and are revoked on logout, password reset,
deactivation, or deletion. Production requires HTTPS; the frontend keeps credentials
only in tab-local `sessionStorage`. Other accounts' IDs are rejected.

Endpoints: `POST /v1/auth/{register,login,logout}`, `GET /v1/auth/session`,
`GET /v1/accounts/:account_id` (own account only),
`GET/PUT /v1/progress`, `GET /v1/data/:lesson_id`, `PUT /v1/data`,
`GET /v1/features`, and `GET /health`. No code execution, REPL, or HTTP administration.
For original-backend behavior, exact calls, and response differences, see the
[user management API comparison](user-management-api.md).

- `users(id, username UNIQUE, password_hash, key_lookup UNIQUE, avatar, created_at, last_login, active)`
- `sessions(token_hash PRIMARY KEY, user_id, created_at, expires_at)`
- `progress(user_id PRIMARY KEY, progress_json, lesson_data_json, updated_at)`

Foreign keys use `ON DELETE CASCADE`; SQL queries are parameterized, with WAL and
a busy timeout. The CLI manages accounts, imports CSV atomically, exports progress,
and uses the SQLite backup API. The metric counts visible chapters and the selected
difficulty level. `COURSE_CHAPTER_IDS` configures chapters and the export metric.

The frontend and backend can run on the same server: under one HTTPS domain, the
reverse proxy forwards `/v1/*` to Puma and everything else to Next.js. They use
local ports 8000/3000 and one SQLite file; the runner remains public and external.
The [deployment guide](../backend/deploy/README.md#deploy-on-one-server)
contains the setup using Caddy for automatic HTTPS and two systemd services; it
also supports an existing Nginx proxy. CLI administration and CSV examples are
in the [backend README](../backend/README.md).
