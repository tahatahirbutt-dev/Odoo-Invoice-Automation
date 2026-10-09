# Technical Journal — Taking Project #1 Public (Aug–Oct 2026)

This log covers moving Project #1 from a laptop-only Docker stack behind a
disposable ngrok tunnel to a permanent public HTTPS deployment (entries 1–12,
August), the October follow-up that separated the public webhook host from the
editor and hardened the stack (entries 13–17), and the groundwork for moving
from the Twilio WhatsApp Sandbox to the Meta Cloud API (webhook verification is
done; sending is not migrated). Workflow bugs are in `DEBUGGING_LOG.md`.

Unlike the earlier logs, most of these aren't code bugs. They're infrastructure
and cloud-provider constraints — which is most of what "getting it deployed"
actually consists of.

---

## 1. Oracle Cloud signup rejected at card verification

**Symptom:** "Oops, we're sorry, an error occurred while creating your account,"
after the card itself showed as successfully verified (Visa, green tick).
**Cause:** Not determinable from the error — Oracle lists incomplete information,
location/identity masking, and duplicate account attempts as possible causes
without indicating which applied. A verification hold was placed on the card on
the first attempt.
**Fix:** Abandoned Oracle. Did not attempt a third signup, since repeated failed
attempts from the same identity risk being treated as duplicate-account abuse.
**Lesson:** When a provider's error names no cause, stop after the retry that can't hurt: repeated attempts from one identity can themselves look like abuse. Move to another route to the same goal instead of diagnosing a black box.

---

## 2. Azure: every VM size unavailable, in every region

**Symptom:** "Select a VM size" showed 1,356 sizes but zero selectable. All were
grouped under four headings: *Size not available*, *Insufficient quota — family
limit*, *Incompatible with Trusted launch virtual machines*, and *Only supported
for Confidential virtual machines*. Validation failed in Central India, Qatar
Central, and East US in turn.
**Cause:** **Trusted launch** security type was silently filtering out the entire
catalogue for this subscription. The failure presented as a regional availability
problem, which sent debugging in the wrong direction for roughly an hour.
**Fix:** Set Security type to **Standard**. B2als_v2 immediately became
selectable in East Asia at $38.40/month.
**Outcome:** Deferred the VM anyway — see entry 3.
**Lesson:** An error that reads "not available in this region" can come from a setting that has nothing to do with regions. When every option fails everywhere, look for one global filter (here the security type) before changing location.

---

## 3. Architecture decision: Cloudflare Tunnel instead of a cloud VM

**Context:** The requirement was a stable public HTTPS URL that external services
(Meta, Twilio) could reach. A cloud VM is one way to get that; it is not the only
way, and it was the one blocked.
**Decision:** Ran a Cloudflare named tunnel against the existing local Docker
stack instead.
**How it works:** `cloudflared` opens an *outbound* connection to Cloudflare's
edge and holds it open. Inbound requests to the public hostname travel back down
that existing connection. No inbound ports, no port forwarding, no public IP.
**Tradeoff accepted:** The stack is only reachable while the host machine is
running. Scheduled workflows do not fire when the laptop is asleep. This is
adequate for demos, webhook verification, and development; it is not production.
**Lesson:** Start from the requirement (a stable public HTTPS URL), not from the first solution. An outbound tunnel met it without a VM, in exchange for availability depending on the host machine, and that trade-off is written down.

---

## 4. Cloudflare Zero Trust checkout demanded a payment method

**Symptom:** Creating a named tunnel through the dashboard led to an "Activate
Zero Trust Free" checkout requiring card details, despite showing $0/month due.
**Cause:** Dashboard-managed tunnels are provisioned through Zero Trust, which
requires a payment method on file even on the free tier.
**Fix:** Used locally-managed tunnels via the `cloudflared` CLI instead
(`tunnel login` → `tunnel create` → `tunnel route dns`), which produces an
identical named tunnel with no Zero Trust activation and no card.
**Side benefit:** Routing config lives in a `config.yml` rather than in a vendor
dashboard. It is gitignored together with the tunnel credentials (`.cloudflared/`);
a sanitized copy is committed as `cloudflared/config.example.yml`.
**Lesson:** A free tier can still ask for a card. Before accepting, check whether another route (here the CLI-managed tunnel) produces the same result without the obligation.

---

## 5. `PUBLIC_BASE_URL` written with `=` inside a YAML mapping block

**Symptom:** `docker compose` failed to parse `docker-compose.yml`.
**Cause:** The line was written as `PUBLIC_BASE_URL=n8n.tahatahirbutt.me` inside
a `environment:` mapping block. Mapping style requires `KEY: value`; the
`KEY=value` form is only valid in list style (`- KEY=value`). The two cannot be
mixed within one block.
**Second, independent error:** the variable had been added to the **odoo**
service rather than the **n8n** service. Environment blocks are per-container, so
n8n — the only service that evaluates `{{$env.PUBLIC_BASE_URL}}` — would never
have received it even had the syntax been valid.
**Fix:** Moved to the `n8n` service as `PUBLIC_BASE_URL: ${PUBLIC_BASE_URL}`,
matching the pass-through pattern already used for the Odoo and Twilio
credentials.
**Verified with:** `docker compose exec n8n printenv`, rather than assuming the
config was correct because it looked correct.
**Lesson:** A config that parses is not a config that works. Ask which container receives each variable, then verify inside that container (`printenv`) instead of trusting how the file looks.

---

## 6. Hardcoded Odoo password surviving an env-var migration

**Symptom:** None. Everything worked.
**Cause:** `Get Customer Contact` passed the literal string `"admin"` as the
third positional argument to `execute_kw` — the password slot — while the three
other Odoo nodes in the same workflow correctly used `{{$env.ODOO_PASSWORD}}`.
Because the local `ODOO_PASSWORD` is also `admin`, both paths resolved to the
same value and no test could distinguish them.
**Why it mattered:** The repo's README claimed no credentials were hardcoded.
The claim was false, and the counter-evidence sat in a file in the same repo.
**Fix:** Replaced with `{{$env.ODOO_PASSWORD}}`. Confirmed against the
`execute_kw(db, uid, password, model, method, args, kwargs)` signature and
against `seed_demo_catalog.py`, which uses the same positional order. Fix was
made node-by-node across sessions; this one was skipped on the first pass and
caught on a later audit — verified directly against the exported JSON, not
against a description of the fix.
**Lesson:** Identical dev values hide wiring mistakes: a literal and a variable that both resolve to `admin` are indistinguishable in a test. Audit the exported files directly, and test with a deliberately different value.

---

## 7. ngrok URL left in workflow JSON after migrating to Cloudflare Tunnel

**Symptom:** `media_url` in `Format WhatsApp Number` still pointed at
`freeness-curliness-unbitten.ngrok-free.dev`.
**Correction:** This was not a dead-tunnel bug — ngrok was still live and
working locally at the time. The project deliberately moved to Cloudflare
Tunnel (see entries 3–4) for a permanent public URL; this node's `media_url`
simply wasn't updated as part of that migration.
**Cause:** Environment-specific value baked into committed workflow JSON,
missed when the underlying infrastructure changed.
**Fix:** `https://{{$env.PUBLIC_BASE_URL}}/webhook/invoice-pdf?invoice_id={{$('Loop Over Invoices').item.json.id}}`
— env-var driven, not hardcoded, so future domain changes don't require editing
workflow JSON.
**Verified:** Resolved output checked directly (`invoice_id=1`), then confirmed
live — two distinct real invoices (`INV/2026/00005`, `INV/2026/00002`) delivered
to WhatsApp successfully, matching correct customer and content.
**Lesson:** When infrastructure changes, search the repo for the old value. Environment-specific addresses belong in environment variables, not in workflow JSON.

---

## 8. Meta Cloud API webhook verification

**What it does:** On saving a callback URL, Meta sends a GET carrying
`hub.mode`, `hub.verify_token`, and `hub.challenge`. The endpoint must compare
the received token against the shared secret and, only on match, return
`hub.challenge` as plain text.
**Implementation:** Webhook (GET) → IF comparing
`$json.query['hub.verify_token']` against `$env.META_VERIFY_TOKEN` → true branch
responds with the challenge; false branch returns 403.
**Result:** Verified live, 54ms, Aug 10.
**Note:** The workflow must be Published — the production `/webhook/` path only
responds when active. Same distinction documented in Project #1's original log.
**What the handshake actually prevents:** Someone registering your URL as a
callback for an app they control, and your endpoint answering challenge
requests from callers who don't hold the shared secret. It proves the endpoint
and the app owner agree on `META_VERIFY_TOKEN`. It does not authenticate later
event deliveries; this workflow only handles verification, and checking event
signatures is not built.
**Lesson:** Published versus test URL again: a webhook that works in the editor but not from outside is almost always an activation problem, so check that first.

---

## 9. Verify token exposed in a shared screenshot

**Symptom:** `META_VERIFY_TOKEN` appeared in plaintext in a screenshot of `.env`
shared outside the machine.
**Cause:** `.env` is correctly gitignored, so the value never reached the repo —
but gitignore protects against commits, not against screenshots.
**Fix:** Rotated the token, updated `.env`, re-entered it in Meta's callback
configuration.
**Lesson:** `.gitignore` protects against commits, not screenshots. A secret that left the machine is burned: rotate it, then change the habit (show variable names or lengths, never values).

---

## 10. CI file invisible to GitHub Actions

**Symptom:** `test-deploy.yml` existed, looked complete, never once appeared in
the Actions tab.
**Cause:** Sat in repo root instead of `.github/workflows/` — GitHub only
recognizes that exact path.
**Fix:** `git mv` to correct path.
**Lesson:** A file "existing" and a file "being used" are different claims —
this is the same category of bug as the `active: false` main workflow, just for
CI instead of a schedule trigger.

---

## 11. `docker-compose` vs `docker compose` in CI

**Symptom:** `test` job failed, exit code 127, `docker-compose: command not
found`.
**Cause:** GitHub's Ubuntu runner ships Docker Compose V2 (plugin, invoked
`docker compose`), not the standalone V1 binary (`docker-compose`) installed
locally. GitHub announced the removal of Compose V1 from its runner images
effective 9 July 2024
(<https://github.blog/changelog/2024-04-10-github-hosted-runner-images-deprecation-notice-docker-compose-v1/>).
**Fix:** sed-replaced all `docker-compose` → `docker compose` in the CI file
only, left local scripts untouched since local environment has the V1 binary
and works fine.
**Lesson:** CI environment ≠ local environment; a green local
`docker-compose up` doesn't guarantee CI parity.

---

## 12. Second, undocumented hardcoded credential — `Serve Invoice PDFs.json`

**Symptom:** None reported before today; found while re-verifying entries 6/7
against the actual exported JSON.
**Cause:** `Get Odoo Session` in the *second* workflow (`Serve Invoice PDFs`)
had its own literal `"login": "admin"` / `"password": "admin"` in the
session-authenticate call — a separate node, in a separate file, from the
`Get Customer Contact` password fixed in entry 6. Same bug class, missed on
the first audit pass because it lives in a different workflow file entirely.
**Fix:** Replaced with `{{$env.ODOO_USER}}` / `{{$env.ODOO_PASSWORD}}`.
Confirmed live on `main` via direct fetch of the pushed file, not assumed from
the commit message.
**Lesson:** A fix verified in one file doesn't cover its siblings; grep every workflow export for the literal. And a replacement has to be executed, not just read: this one looked right in the pushed file but was never evaluated (see `DEBUGGING_LOG.md`, bug 12).

---

## 13. Twilio said `queued`, the invoice never arrived — Cloudflare Access was in the way

**Symptom:** `Send via Twilio` succeeded (`status: queued`), the audit row said
`sent`, and no WhatsApp message arrived. `Serve Invoice PDFs` had no execution
at the send time. Every earlier test had used `localhost`.
**Cause:** A Cloudflare Access application protected the whole `n8n.` hostname,
including `/webhook/invoice-pdf`. A request to the public URL returned `302` to
`*.cloudflareaccess.com/cdn-cgi/access/login`. Twilio can't log in, so its media
fetch got an HTML redirect and the message was never delivered. Nothing in n8n
could show this, because the request never reached it.
**Fix:** First a temporary Bypass application for exactly `webhook/invoice-pdf`
(verified: signed link `200 application/pdf` on the public URL, unsigned `403`,
`/healthz` still `302`). Then the permanent design in entry 14.
**Lesson:** Test the path an external caller takes, from outside. A green local
test says nothing about the tunnel, DNS or the access layer in front of it.

---

## 14. Decision: separate public webhook host from the editor host

**Context:** The bypass app (entry 13) left one hostname that was both the
protected editor and, for one path, public.
**Decision:** Two hostnames on the same tunnel.
- `hooks.` is public, and the tunnel's ingress `path:` regex forwards only
  `/webhook/invoice-pdf` and `/webhook/whatsapp-webhook`; everything else hits
  the catch-all `http_status:404`.
- `n8n.` is the editor behind Cloudflare Access, with no public path at all.
`WEBHOOK_URL` points at `hooks.`, `N8N_EDITOR_BASE_URL` at `n8n.`, and
`PUBLIC_BASE_URL` (used to build the media link) at `hooks.`.
**Verified:** On `hooks.`: signed link `200 application/pdf`, unsigned `403`,
and `/`, `/signin`, `/healthz` all `404`. After the bypass app was deleted, both
the PDF path and `/healthz` on `n8n.` return `302` to the Access login. A real
invoice then reached WhatsApp through the new route.
**Tradeoff:** The ingress regex must be kept in sync with the webhook paths in
n8n; a new public webhook needs a tunnel change. That is deliberate.
**Lesson:** Prefer shrinking what is public over adding exceptions to what is
private. An allow-list at the edge is easier to reason about than a bypass.

---

## 15. Tunnel ingress `path:` written as a full URL

**Symptom:** None at first. `tunnel ingress validate` said OK.
**Cause:** The `path:` field is a regex matched against the URL **path**. A full
URL (`https://hooks…/webhook/whatsapp-webhook`) had been pasted into the
alternation, so the second path could never match and Meta's callback would
have received 404s while the PDF path kept working.
**Fix:** `^/webhook/(invoice-pdf|whatsapp-webhook)$`.
**Caught by:** `cloudflared tunnel ingress rule <url>`, which prints the rule a
URL matches, run for both allowed paths and for two that must be blocked,
*before* restarting the tunnel.
**Lesson:** `validate` checks syntax, not intent. Test each rule with a URL that
should match and one that should not.

---

## 16. n8n database variables renamed to names n8n doesn't read

**Symptom:** None, because it was caught before the container was recreated.
**Cause:** In `docker-compose.yml`, `DB_POSTGRESDB_USER` / `DB_POSTGRESDB_PASSWORD`
had been renamed to `N8N_DB_POSTGRESDB_USER` / `…PASSWORD` while moving values
into `.env`. n8n reads the `DB_POSTGRESDB_*` names, so on the next recreate it
would have fallen back to a default login that doesn't exist in this Postgres
and crash-looped. A static check found it: every `${VAR}` resolved, but the
*left-hand* names were wrong.
**Fix:** Keep the `.env` key names; restore the container-side names
(`DB_POSTGRESDB_USER: ${N8N_DB_POSTGRESDB_USER}`).
**Verified:** After `docker compose up -d n8n`, n8n started, registered and
activated its workflows.
**Lesson:** The `.env` name and the variable the application reads are two
different things. Check the left side of every compose line against the app's
documentation, then check the logs after the recreate.

---

## 17. A fresh clone could not start

**Symptom:** None on the original machine, which had the databases created by
hand.
**Cause:** Nothing created `n8n_db`, so n8n could not connect on a new volume,
and the QUICKSTART only mentioned one of the two manual `createdb` steps.
`init.sql` was also mounted into the image's init directory, which runs it
against the default database (`odoo`) rather than `invoice_automation_logs`.
**Fix:** `docker/initdb/00-databases-and-schema.sql` creates both databases
and loads `init.sql` into the right one, on first start of an empty volume
only (existing volumes are untouched). `init.sql` itself is unchanged apart
from comments and one added view column.
**Verified:** Run against a throwaway PostgreSQL 16 cluster using the same
flags the image uses: both databases created, the table exists in
`invoice_automation_logs` and not in `odoo`, re-running `init.sql` is safe. CI
now repeats this with the real compose file on every push (first CI run still
pending when this was written).
**Lesson:** "Works on my machine" includes the state of the machine. Start from
an empty volume as part of the test, not only from the one that already works.

---

## Known gaps (not yet fixed — documented honestly)

**Fixed since the August version of this list:** string-interpolated SQL (the
logging nodes are parameterized), and the loop advancing in parallel with the
send so that failed sends left no audit row (every branch now returns to the
loop and failures are logged as `failed`; that branch has not been exercised
yet). Details in `DEBUGGING_LOG.md`, bugs 9 and 13.

**Still open:**
- **`sent` means "accepted by Twilio".** The audit table can't tell a delivered
  message from one that failed later (entry 13 was exactly that). A Twilio status
  callback is the fix; not built.
- **Skipped invoices are logged again on every run.** They stay eligible so
  they send once a number is added, but the audit table grows by one row per
  skipped invoice per run.
- **Access token is temporary.** Meta Cloud API is running on a 24-hour user
  token. A System User token with `whatsapp_business_messaging` and
  `whatsapp_business_management`, expiry Never, is required before any real use.
- **Workflows still send via Twilio.** Meta Cloud API webhook verification
  works, but the send path has not been migrated, and event deliveries are not
  signature-checked.
- **Deployment is laptop-hosted.** Not a server. Scheduled workflows only run
  while the machine is awake.
- **Main workflow (`Invoice Automation - WhatsApp Delivery`) is deliberately
  inactive.** Twilio's free trial caps outbound WhatsApp at 5 messages/day and
  the Sandbox connection requires periodic re-join (see `DEBUGGING_LOG.md`,
  entries 7–8). An always-on 2-hour schedule trigger against that tier would
  produce a few successful sends followed by failures until the cap resets or
  the sandbox is rejoined. Activation is gated on either a paid Twilio tier or
  the planned Meta Cloud API migration, not on a remaining bug in this workflow.
