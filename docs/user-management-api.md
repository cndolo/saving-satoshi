# User management API: original and course backend

This is a source-level comparison of the original Saving Satoshi backend at
[`eb722112`](https://github.com/saving-satoshi/saving-satoshi-backend/tree/eb72211295f4ac792bc879f08f1aa071e3e9bc1c)
(the `master` and `develop` heads checked on 13 October 2026) with this course
backend. It covers every original HTTP route that creates, authenticates, or reads
an account, plus the account-owned progress and lesson data routes. The frontend
used for the comparison is the frontend at commit `0e11d91017d2b4fa47745f4f4ad95eec46f1c6d5`
with the small course changes in this project.

## Endpoint inventory

All paths are relative to the REST API origin. `Auth` means an
`Authorization: Bearer <token>` header. The original authenticated middleware
reads that header; its login cookie does not authenticate these routes by itself.

| Method and path               | Auth | Original behavior                                                                                                                   | Course behavior                                                                                                                                                                  | Frontend call                 |
| ----------------------------- | ---- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| `POST /v1/auth/register`      | No   | Creates an account and an initial `CH1INT1` progress row; returns `200 {"id":…}`.                                                   | Creates a random `self-…` username, hashes the key, optionally copies guest progress; returns `201` with public account fields. Can be disabled with `ALLOW_REGISTRATION=false`. | `api/auth/register.ts`        |
| `POST /v1/auth/login`         | No   | Finds a plaintext private key; returns `200 {"id":…, "token":…}` and sets a cookie.                                                 | Verifies a bcrypt hash; returns `200 {"token":…}`.                                                                                                                               | `api/auth/login.ts`           |
| `GET /v1/auth/session`        | Yes  | Returns `{id,private_key,avatar}` from the signed token.                                                                            | Returns `{id,username,avatar,created_at,last_login}` without the key. The frontend adds its tab-local key for the existing account dialog.                                       | `api/auth/getSession.ts`      |
| `POST /v1/auth/logout`        | Yes  | Clears the login cookie; returns `200 {}`. It does not revoke the JWT.                                                              | Deletes the current server session; returns `200 {"ok":true}`.                                                                                                                   | `api/auth/logout.ts`          |
| `GET /v1/accounts/:accountId` | Yes  | Returns an account by numeric ID, omitting `private_key`. Any authenticated account can request any ID.                             | Returns only the authenticated user's public account fields. Invalid ID `400`, another ID `403`.                                                                                 | None in this frontend         |
| `GET /v1/progress`            | Yes  | Returns `{account,progress,progress_state}`; a newly registered account starts with `progress="CH1INT1"` and `progress_state=null`. | Returns `{progress_state,updated_at}`; a new account has `progress_state=null` until saved.                                                                                      | `api/progress/getProgress.ts` |
| `PUT /v1/progress`            | Yes  | Accepts `{progress_state}` and uses its `currentLesson` as the progress label; returns the database row.                            | Validates and saves the complete state for the authenticated account; returns `{ok:true}`.                                                                                       | `api/progress/setProgress.ts` |
| `GET /v1/data/:lesson_id`     | Yes  | Returns `{lesson_id,data}` for the authenticated account. An absent row currently becomes a server error.                           | Returns `{data}`; an absent row is `404`.                                                                                                                                        | `api/data/getData.ts`         |
| `PUT /v1/data`                | Yes  | Saves `{lesson_id,data}` for the authenticated account and returns the row.                                                         | Saves the same fields; accepts the existing frontend's `account_id` only if it matches the session; returns `{ok:true}`.                                                         | `api/data/setData.ts`         |

The original route list is in
[`src/routes/v1/index.ts`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/src/routes/v1/index.ts).
Details are in its
[`auth.ts`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/src/routes/v1/auth.ts),
[`accounts.ts`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/src/routes/v1/accounts.ts),
[`progress.ts`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/src/routes/v1/progress.ts), and
[`data.ts`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/src/routes/v1/data.ts).
There is no original HTTP endpoint to list, rename, deactivate, delete, or reset
accounts. The course backend supplies those administrative operations through
`backend/bin/admin`, including CSV import and progress export.

The original `GET /v1/features` is public and controls chapter visibility. This
backend provides the same `feature_name` and `feature_value` fields from
`COURSE_CHAPTER_IDS`. Its `PUT /v1/features` and `/v1/status` are outside account
management and are not used by this frontend; the course backend provides
`GET /health` for its own health check. No runner or REPL route is part of this
service. The runner uses `NEXT_PUBLIC_WS_ENDPOINT` independently of the REST URL.

## Authentication and storage differences

The frontend's **private key** field is the login credential, not the
administrative username. Use a random **32-byte key represented by exactly 64
hexadecimal characters**. A 64-byte key represented by 128 hex characters is
invalid. The course backend additionally requires a valid nonzero secp256k1 key;
uppercase hex is accepted. The original login checks only the 64-character
length. The account dialog cannot sign in with a username.

The original
[`accounts.private_key`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/prisma/schema.prisma)
column stores that credential directly. Its JWT contains account data, including
the key, and has no explicit expiry in
[`token.ts`](https://github.com/saving-satoshi/saving-satoshi-backend/blob/eb72211295f4ac792bc879f08f1aa071e3e9bc1c/src/lib/token.ts).
The course backend stores a bcrypt hash and a SHA-256 lookup value, never the
plaintext key. It issues a random bearer token, stores only its hash in SQLite,
expires it after eight hours by default, and revokes it on logout, password reset,
deactivation, or deletion. A disabled user cannot sign in or use an old session.
All progress and lesson data queries use the authenticated account ID. The course
`GET /v1/accounts/:accountId` also refuses other account IDs.

The original backend uses PostgreSQL tables for accounts, progress, and lesson
data. The course backend uses one SQLite file with `users`, `sessions`, and
`progress` tables; progress and lesson data are JSON. The course backend adds
`username`, creation time, last login, and active status for administration.

## Request examples and expected results

The following bodies show the course API wire format; replace placeholders
before sending. Its REST origin is `http://localhost:8000` in the local setup.
Never put a real key or token in a URL, command argument, shared log, or
committed file.

| Action           | JSON request body                                                                              | Success                                                           | Common failure                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------- |
| Register         | `{"private_key":"<64-hex>","avatar":"/assets/avatars/1.png","progress_state":null}`            | `201`, public account fields                                      | `409` duplicate, `422` invalid key/avatar/progress, `403` if disabled |
| Login            | `{"private_key":"<64-hex>"}`                                                                   | `200 {"token":"<64-hex>"}`                                        | `400` malformed key, `401` unknown/disabled key, `429` rate limit     |
| Read session     | No body; bearer header                                                                         | `200`, public account fields                                      | `401` missing/invalid/expired session                                 |
| Logout           | `{}`; bearer header                                                                            | `200 {"ok":true}`                                                 | `401` missing/invalid/expired session                                 |
| Read own account | No body; bearer header; own numeric ID in path                                                 | `200`, public account fields                                      | `400` invalid ID, `401` no session, `403` another ID                  |
| Read progress    | No body; bearer header                                                                         | `200 {"progress_state":null,"updated_at":null}` for a new account | `401` no session                                                      |
| Save progress    | `{"progress_state":<CourseProgress>}`; bearer header                                           | `200 {"ok":true}`                                                 | `401` no session, `422` invalid state                                 |
| Read lesson data | No body; bearer header; lesson ID in path                                                      | `200 {"data":{…}}`                                                | `401` no session, `404` no saved data                                 |
| Save lesson data | `{"lesson_id":"CH1INT1","data":{"answer":[],"code":"<base64>"},"account_id":1}`; bearer header | `200 {"ok":true}`                                                 | `401` no session, `403` wrong account ID, `422` invalid body          |

The frontend sends `Content-Type: application/json`; protected calls send the
bearer header. `account_id` on lesson-data writes is optional at the backend and
never selects the target user. `CourseProgress` contains `currentChapter`,
`currentLesson`, and `chapters`; each chapter contains lessons and completion
flags, or a selected difficulty track. See `state/progress/defaultProgress.ts`
for the actual client structure. The API responds to errors with
`{"errors":["message"]}` and uses `404` for unknown routes. Error text is not
a stable protocol; clients should use HTTP status codes.

The normal browser sequence is: register (for self-created accounts), then
login, then read session and progress; save progress or lesson data during the
course; logout when finished. CLI or CSV-created accounts begin at login.
The frontend does not call the account-detail or feature-write routes.

## Configuration and verification

Set `NEXT_PUBLIC_API_ENDPOINT` to the REST **origin**, without `/v1` or a
trailing slash. Set `NEXT_PUBLIC_WS_ENDPOINT=wss://api.savingsatoshi.com` to
keep the public runner. For a browser at `http://localhost:3000`, the defaults
allow requests to `http://localhost:8000`. If students open the frontend by
another hostname or IP, set `ALLOWED_ORIGINS` to that exact browser origin,
`ALLOWED_HOSTS` to the backend hostname, and make `BIND` reachable from their
browser. The backend and CLI must use the **same `DATABASE_PATH`**. The frontend
does not open SQLite itself. On one public server, a single HTTPS origin can
reverse-proxy `/v1/*` to Puma and other paths to Next.js; see the
[deployment guide](../backend/deploy/README.md#deploy-on-one-server).

If sign-in appears to do nothing, inspect the browser's Network tab for
`/v1/auth/login`. The unchanged sign-in dialog currently gives no visible error
for a rejected or unreachable login request. A `400` usually means the key has
the wrong format; `401` means the key is unknown or its account is disabled;
`403` can mean the browser origin or host is not allowed. A failed network
request usually means the browser cannot reach its configured REST origin.
`localhost` refers to the **browser's computer**, which may differ from the
server running Puma.

The backend API tests cover registration, login, session loading, revocation,
expiry, account isolation, progress, lesson data, CORS, and invalid requests.
They run against temporary SQLite files, so they do not touch a course database:

```sh
cd backend
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require_relative f }'
```

These tests check local behavior and the source contract; they do not call the
public Saving Satoshi service or prove that a particular deployment's DNS,
proxy, browser origin, or runner connection is configured correctly.
