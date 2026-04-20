# Google Workspace email path — ADVANCED / BYO (deferred past Stage 7)

> **⚠️ Deferred (2026-04-19).** This runbook is now an **advanced bring-your-own path**, not the default for Stage 5 or Stage 6. The Stage 6 default is hosted `xxxxx@agentkeys-email.io` on AgentKeys infrastructure — zero setup for non-developers. See `docs/spec/ses-email-architecture.md` and [`wiki/hosted-first.md`](../wiki/hosted-first.md) for the hosted default, and `docs/spec/plans/development-stages.md` for the revised stage roadmap.
>
> **Preserved here** for operators who specifically want to run AgentKeys email inside their existing Google Workspace (enterprise / regulated / data-residency reasons). The architecture is parallel to the hosted SES path — same three-layer abstraction, same Touch-ID gate, same chain audit — just a different cloud.

**Purpose.** An alternative to the plus-addressed-personal-Gmail + app-password flow
described in `docs/manual-test-stage5.md` § 1. Use this path when you run a Google
Workspace domain and want the live OpenRouter provision demo (and every future
Stage 5 automation) to spin up throwaway identities inside that domain, read their
mail via the Gmail API, and tear them down at the end. No personal inbox involved,
no app password, no human-interactive consent per run.

**Scope.** One-time super-admin setup + per-run workflow. Assumes you already own
a Google Workspace subscription for your domain (e.g. `wildmeta.ai`).

> **Design rationale and backend comparison.** This doc is the *operator runbook*
> for the GCP-managed-key variant. For the *design decision* — why we have two
> email-signing backends (GCP-managed vs AgentKeys TEE), how they plug into the
> existing `CredentialBackend` trait, how the 30-day session-key policy and the
> Touch ID gate (#11) apply to both — see
> [`docs/spec/email-signing-backends.md`](spec/email-signing-backends.md).
> Short version: this GCP path is Stage 5's alternative backend; v0.1 migrates to
> the AgentKeys TEE path; both satisfy the same trait so the CLI and daemon code
> never change.

---

## When to use which path

| Your situation | Use |
|---|---|
| Personal `@gmail.com`, one-off manual test | `manual-test-stage5.md` § 1 (plus-addressing + app password) |
| Google Workspace domain, CI-friendly automation, recurring demos | **this doc** |
| Company Workspace, one-off manual test | either, but this doc once the 20-minute admin setup is done — it pays for itself after ~2 demo runs |

The Workspace path has strictly better properties for automation:

- **No personal inbox pollution** — throwaway users are isolated, visible in a
  dedicated `/Automation` OU, and deleted after each run.
- **No human-held secrets in env vars** — the only secret is a GCP service-account
  JSON key, which lives in a secret manager and is rotated by CI, not by a person.
- **Non-interactive** — zero OAuth consent screens per run; `agent@wildmeta.ai`
  uses its admin role for user CRUD, the service account impersonates the
  throwaway user for Gmail reads.
- **Auditable** — every user create/delete shows up in the Workspace admin audit
  log; every Gmail read shows up in the service account's GCP audit log.

---

## What `@gmail.com` *cannot* do (and why this matters)

Google does **not** expose an API to create personal `@gmail.com` accounts. The
public signup flow is reCAPTCHA-gated and browser-only. This means:

- Plus-addressed personal Gmail (`you+stage5test@gmail.com`) is the only "new
  identity per run" option you get without a Workspace subscription — but every
  OpenRouter confirmation still lands in your real inbox.
- With a Workspace domain, you can genuinely mint a fresh identity per demo
  (`stage5test-20260418@yourdomain`) and delete it when done.

If the long-term plan is "every Stage 5 provision run spins up a fresh identity",
this path is the only one that actually scales.

---

## Architecture

```
                     ┌─────────────────────────┐
                     │  agent@wildmeta.ai      │
                     │  (non-admin Workspace   │
                     │   user, assigned the    │
                     │   stage5a-provisioner   │
                     │   custom admin role)    │
                     └────────────┬────────────┘
                                  │ gws auth login (OAuth)
                                  │ scope: admin.directory.user
                                  ▼
              ┌────────────────────────────────────┐
              │  gws admin users.insert/.delete    │
              │  (in /Automation OU only)          │
              └────────────────────────────────────┘
                                  │
                                  │ creates
                                  ▼
               stage5test-<timestamp>@wildmeta.ai

                     ┌─────────────────────────┐
                     │  stage5a-sa@...          │
                     │  GCP service account     │
                     │  + Domain-Wide Delegation│
                     │  scopes: gmail.readonly, │
                     │          gmail.modify    │
                     └────────────┬────────────┘
                                  │ impersonates any wildmeta.ai user
                                  ▼
              ┌────────────────────────────────────┐
              │  gws gmail users.messages.list/get │
              │  (reads throwaway user's inbox for │
              │   the OpenRouter OTP)              │
              └────────────────────────────────────┘
```

Two identities do two jobs:

1. **`agent@wildmeta.ai`** — a regular Workspace user with a narrow custom admin
   role that lets it create and delete users in one OU only. Humans log into this
   account; OAuth handles its scopes.
2. **`stage5a-sa@...` (service account)** — not a user. Used purely to impersonate
   throwaway users over the Gmail API via Domain-Wide Delegation. Its JSON key
   lives in a secret manager.

Neither identity can substitute for the other: the service account cannot create
or delete users (that would need Admin SDK domain-wide delegation, which is a
deliberate decision not to grant), and `agent@wildmeta.ai` cannot read other
users' mail (no user ever can — only DWD service accounts can).

---

## What "non-interactive" means — a concrete trace

"Non-interactive" means **no human ever sees a browser, a consent screen, or a
password prompt after one-time setup**. The one-time setup spends some interactive
effort (super-admin clicks through A3 and B4; `agent@wildmeta.ai` runs `gws auth
login` once). After that, a demo run involves zero UI.

### Example: reading the OpenRouter OTP from a throwaway user's inbox

**Preconditions (all already true by the time the demo runs):**

- `~/stage5a-sa.json` exists on disk (from B5)
- `stage5test-20260419@wildmeta.ai` exists (created 60 s earlier by this same run)
- That throwaway user has **never logged in** — it has no browser session, no
  saved password on any device, and no human who knows its password
- `agent@wildmeta.ai`'s local `~/.config/gws/` already holds a refresh token
  from the one-time `gws auth login`

**The command the script runs:**

```bash
GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=~/stage5a-sa.json \
GOOGLE_WORKSPACE_CLI_IMPERSONATE=stage5test-20260419@wildmeta.ai \
gws gmail users.messages.list \
  --params '{"userId":"me","q":"from:noreply@openrouter.ai"}'
```

**What happens under the hood — zero human involvement, ~300 ms end to end:**

```
1. gws loads stage5a-sa.json  → gets (client_email, private_key)
2. gws builds a JWT:
       iss:   stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com
       sub:   stage5test-20260419@wildmeta.ai      ← the impersonation target
       scope: https://www.googleapis.com/auth/gmail.readonly
       aud:   https://oauth2.googleapis.com/token
       iat:   <now>, exp: <now + 1h>
       signed: RSA-SHA256 with the SA's private key
3. POST https://oauth2.googleapis.com/token
       grant_type = urn:ietf:params:oauth:grant-type:jwt-bearer
       assertion  = <the signed JWT above>

   Google's token endpoint validates:
     - SA exists + key signature is valid
     - SA is authorized for DWD on wildmeta.ai with gmail.readonly   ← from B4
     - sub user (stage5test-20260419@wildmeta.ai) exists in wildmeta.ai

   → returns an access_token scoped to "read stage5test-20260419's Gmail"

4. GET https://gmail.googleapis.com/gmail/v1/users/me/messages?q=...
       Authorization: Bearer <access_token>

   → Gmail returns the message list as JSON.
```

**Zero browser windows opened. Zero consent screens. Zero password prompts.**
The access token is minted, used, and thrown away inside one shell command.

### Contrast: what *would* be interactive

If we didn't have the DWD service account, the equivalent Gmail read would need
one of these instead, all of which break automation:

| Alternative | Why it's interactive |
|---|---|
| OAuth as the throwaway user | Needs a browser → "Sign in as stage5test-20260419" → consent screen → "Allow". Per run. There's no one at the keyboard for an ephemeral user. |
| Gmail IMAP with app password | App password generation requires the user to be logged in to myaccount.google.com (browser) and have 2FA enrolled (requires phone). Throwaway users can't do either. |
| Gmail IMAP with OAuth XOAUTH2 | Same OAuth consent dance as row 1, just for IMAP instead of the REST API. |
| `gws auth login` as the throwaway user | `gws auth login` opens a browser by design. Throwaway users aren't staffed. |

DWD sidesteps all of them because the consent was granted **once**, at B4, by
the super-admin: *"this service account is allowed to wear any wildmeta.ai
user's Gmail hat with these scopes."* After that, per-user impersonation is a
signed JWT away — no user-side consent required, because the domain itself
already consented on their behalf.

### What about `agent@wildmeta.ai`'s OAuth?

`agent@wildmeta.ai` does go through a consent screen **exactly once** — the
first time it runs `gws auth login`. That writes a refresh token to
`~/.config/gws/`. From then on:

- Every `gws admin users.insert` / `users.delete` call silently exchanges the
  refresh token for a fresh access token against Google's token endpoint.
- No browser opens.
- Refresh tokens for Workspace OAuth apps are long-lived (don't expire unless
  revoked or unused for 6 months).

So: one browser visit at setup time, then a quiet lifetime of scripted calls.

---

## One-time setup

The full checklist. Steps A1–A3 grant user-CRUD privileges to `agent@wildmeta.ai`.
Steps B1–B5 create the service account and authorize it for Gmail impersonation.
Only **A3** and **B4** require super-admin; everything else is delegable.

### A1. Create the `/Automation` OU

Admin Console → Directory → Organizational units → Create child unit.

- Name: `Automation`
- Parent: `/`

This OU holds throwaway users and bounds the custom admin role below.

### A2. Create the `stage5a-provisioner` custom admin role

Admin Console → Account → Admin roles → Create new role.

- Name: `stage5a-provisioner`
- Privileges:
  - Users → **Create** ✓
  - Users → **Delete** ✓
  - Users → **Update** ✓
  - Organizational Units → **Read** ✓

Do not grant any other privilege. No super-admin, no Gmail admin, no security
center, no groups admin.

### A3. Assign the role to `agent@wildmeta.ai`, scoped to `/Automation`

*(super-admin action)*

Admin Console → Account → Admin roles → `stage5a-provisioner` → Assign admin →
`agent@wildmeta.ai`.

- Scope: **Only selected organizational units** → add `/Automation`.

Do **not** leave the default "All organizational units" selected — that would
give `agent@wildmeta.ai` create/delete rights over real employees.

### B1. Create the GCP project

```bash
gcloud projects create wildmeta-agent-provisioner \
  --name="Agent Provisioner"
```

Grant `agent@wildmeta.ai` **Owner** on this project (or the tighter
**Service Account Token Creator** if you want to prevent it from editing project
settings):

```bash
gcloud projects add-iam-policy-binding wildmeta-agent-provisioner \
  --member=user:agent@wildmeta.ai \
  --role=roles/owner
```

### B2. Enable the required APIs

```bash
gcloud services enable \
  admin.googleapis.com \
  gmail.googleapis.com \
  --project=wildmeta-agent-provisioner
```

### B3. Create the service account

```bash
gcloud iam service-accounts create stage5a-sa \
  --display-name="Stage 5a provisioner" \
  --project=wildmeta-agent-provisioner
```

Record the email: `stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com`.

### B4. Authorize domain-wide delegation

*(super-admin action — and the **only** DWD step per service account; see
"Is B4 one-time?" below)*

Admin Console → Security → Access and data control → API controls → Domain-wide
delegation → **Add new**.

- **Client ID**: the service account's numeric unique ID. Find it with:
  ```bash
  gcloud iam service-accounts describe \
    stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com \
    --format='value(oauth2ClientId)'
  ```
- **OAuth scopes** (comma-separated, one field):
  ```
  https://www.googleapis.com/auth/gmail.readonly,
  https://www.googleapis.com/auth/gmail.modify
  ```

### B5. Mint the key and hand it off

```bash
gcloud iam service-accounts keys create ~/stage5a-sa.json \
  --iam-account=stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com
# created key [f720…] of type [json] as [~/stage5a-sa.json]
```

Put `~/stage5a-sa.json` in a secret manager. Never commit. Share with the
principal(s) that will run the demo — GCP Secret Manager with
`roles/secretmanager.secretAccessor` granted to `agent@wildmeta.ai` is the
cleanest channel, 1Password shared-vault works for manual flows.

---

## Is B4 one-time?

Yes — and this is the property that makes the whole scheme worth the setup cost.

| Action | Re-do B4? |
|---|---|
| Create `stage5test-<timestamp>@wildmeta.ai` and read its Gmail | ❌ No |
| Create any number of new users (`b4-s@wildmeta.ai`, `ci-bot@wildmeta.ai`, …) | ❌ No |
| Delete and recreate a user with the same email | ❌ No |
| Rotate the **service-account key** (JSON file) | ❌ No — DWD binds to the SA's client ID, not its key material |
| Add a new scope (e.g. `gmail.compose`) | ⚠️ Edit the existing DWD entry and append the scope — super-admin action |
| Create a **second** service account | ✅ Yes — DWD is per-SA |
| Move to a different Workspace domain | ✅ Yes — DWD is per-domain |

Day-to-day: new throwaway users cost one `gws admin users.insert` call and zero
admin involvement.

---

## Per-demo-run workflow

Assumes one-time setup is complete and `~/stage5a-sa.json` is readable by the
principal running the demo.

### Log in to `gws` as the agent user (once per session)

```bash
gws auth login -s admin.directory.user
```

### Mint a throwaway user

```bash
EMAIL="stage5test-$(date +%s)@wildmeta.ai"
PASSWORD="$(openssl rand -base64 24)"

gws admin users.insert --json "{
  \"primaryEmail\": \"$EMAIL\",
  \"name\": {\"givenName\": \"Stage5\", \"familyName\": \"Test\"},
  \"password\": \"$PASSWORD\",
  \"changePasswordAtNextLogin\": false,
  \"orgUnitPath\": \"/Automation\"
}"
```

Workspace takes 30–60 seconds to replicate the new user across services (Gmail,
Directory); give it a sleep before the demo hits the inbox:

```bash
sleep 60
```

### Run the demo pointed at this user

```bash
export AGENTKEYS_EMAIL_USER="$EMAIL"
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$HOME/stage5a-sa.json"
export GOOGLE_WORKSPACE_CLI_IMPERSONATE="$EMAIL"

agentkeys provision openrouter
```

The Gmail fetcher uses the SA key + `IMPERSONATE` to read the throwaway user's
inbox over the Gmail API — no password, no IMAP, no app password.

> **Code change required.** The current `provisioner-scripts/src/lib/email.ts`
> uses `imapflow` against `imap.gmail.com:993` — it has no Gmail-API backend.
> To make this path work end-to-end, replace the IMAP fetcher with a Gmail-API
> fetcher that reads from `gws gmail users.messages.list/get` (or the
> `googleapis` npm package directly) using the service-account credentials above.
> Tracked as a follow-up; the setup in this doc is a prerequisite for that
> change but stands on its own as the documented admin path.

### Teardown

```bash
gws admin users.delete --params "{\"userKey\":\"$EMAIL\"}"
```

---

## Secret management

| Secret | Where it lives | Who can read |
|---|---|---|
| Service account JSON key | GCP Secret Manager (preferred) or 1Password shared vault | `agent@wildmeta.ai` + CI runner |
| `agent@wildmeta.ai` OAuth tokens | `~/.config/gws/` on whichever machine ran `gws auth login` | that machine's local user |
| Throwaway user password | Emitted to stdout at creation, discarded — we never log in interactively as the throwaway user, so it doesn't need to be stored | — |

Do not check `stage5a-sa.json` into git, not even encrypted. `agentkeys` already
has `.gitignore` coverage for `*.json` under config paths; extend it if your
working copy of the key lives somewhere surprising.

---

## Rotation

Quarterly (or after any key exposure):

```bash
# Mint a new key
gcloud iam service-accounts keys create ~/stage5a-sa-new.json \
  --iam-account=stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com

# Update the secret manager / CI runner to use the new file

# List existing keys to confirm both are active
gcloud iam service-accounts keys list \
  --iam-account=stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com

# After confirming the new key works in one demo run, delete the old key by ID
gcloud iam service-accounts keys delete <OLD_KEY_ID> \
  --iam-account=stage5a-sa@wildmeta-agent-provisioner.iam.gserviceaccount.com
```

No admin console involvement — DWD is bound to the SA's client ID, not to the
specific key file, so rotating keys is invisible to the Workspace side.

---

## Teardown (full retire-the-setup)

If you decide this path was a mistake and want to back out cleanly:

1. `gcloud iam service-accounts delete stage5a-sa@…` — removes the SA and
   implicitly invalidates all its keys.
2. Admin Console → Domain-wide delegation → remove the `stage5a-sa` entry.
3. Admin Console → Admin roles → `stage5a-provisioner` → Delete role.
4. Admin Console → Directory → Organizational units → delete any remaining
   users in `/Automation`, then delete the OU itself.
5. `gcloud projects delete wildmeta-agent-provisioner` — deletes the GCP project.

After step 1 the blast radius is already fully contained (no live credential can
reach Workspace). Steps 2–5 are cleanup.

---

## Cross-references

- `docs/manual-test-stage5.md` § 1 — the plus-addressing alternative (keep as-is;
  this doc is the alternative for Workspace users)
- `provisioner-scripts/src/lib/email.ts` — currently IMAP-only; needs a Gmail-API
  backend for this path to be end-to-end usable
- `crates/agentkeys-provisioner/` — the Rust orchestrator is unchanged; only the
  TS email fetcher needs the new backend
- `TODOS.md` — OpenRouter ToS compliance check still blocks the *first* live run
  on either path
