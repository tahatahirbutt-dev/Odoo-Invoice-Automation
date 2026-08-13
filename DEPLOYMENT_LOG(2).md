# Technical Journal — Taking Project #1 Public (Aug 2026)

> DRAFT. The `**Lesson:**` lines are deliberately blank — fill them in yourself
> before committing. If you can't write the lesson, you don't own the bug yet.

This log covers moving Project #1 from a laptop-only Docker stack behind a
disposable ngrok tunnel to a permanent public HTTPS deployment, and retiring the
Twilio WhatsApp Sandbox in favour of the Meta Cloud API.

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
**Lesson:**

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
**Lesson:**

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
**Lesson:**

---

## 4. Cloudflare Zero Trust checkout demanded a payment method

**Symptom:** Creating a named tunnel through the dashboard led to an "Activate
Zero Trust Free" checkout requiring card details, despite showing $0/month due.
**Cause:** Dashboard-managed tunnels are provisioned through Zero Trust, which
requires a payment method on file even on the free tier.
**Fix:** Used locally-managed tunnels via the `cloudflared` CLI instead
(`tunnel login` → `tunnel create` → `tunnel route dns`), which produces an
identical named tunnel with no Zero Trust activation and no card.
**Side benefit:** Routing config lives in a `config.yml` in the repo rather than
in a vendor dashboard.
**Lesson:**

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
**Lesson:**

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
**Lesson:**

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
**Lesson:**

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
**What the handshake actually prevents:**
**Lesson:**

---

## 9. Verify token exposed in a shared screenshot

**Symptom:** `META_VERIFY_TOKEN` appeared in plaintext in a screenshot of `.env`
shared outside the machine.
**Cause:** `.env` is correctly gitignored, so the value never reached the repo —
but gitignore protects against commits, not against screenshots.
**Fix:** Rotated the token, updated `.env`, re-entered it in Meta's callback
configuration.
**Lesson:**

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
locally. *(Worth a quick check against GitHub's current runner image docs
before this goes in the repo — runner images change and this wasn't verified
against a live source.)*
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
**Lesson:**

---

## Known gaps (not yet fixed — documented honestly)

- **Postgres logging uses string-interpolated SQL.** Both logging nodes build
  INSERT statements by concatenation. Current inputs are effectively safe
  (Odoo-generated invoice numbers, digit-stripped phone numbers), but
  `customer_name` and phone fields are user-editable in Odoo, so a single
  apostrophe would break the statement. Should be parameterized via the Postgres
  node's Insert operation.
- **Loop advances in parallel with the send.** `Format WhatsApp Number` connects
  to both `Loop Over Invoices` and `Send via Twilio` simultaneously, so the loop
  moves on before the send result is known. A Twilio failure therefore produces
  no audit row at all, since `Log Delivery to Postgres` only sits on the success
  path. The audit table under-reports failures.
- **Access token is temporary.** Meta Cloud API is running on a 24-hour user
  token. A System User token with `whatsapp_business_messaging` and
  `whatsapp_business_management`, expiry Never, is required before any real use.
- **Workflows still send via Twilio.** Meta Cloud API is verified but the send
  path has not been migrated.
- **Deployment is laptop-hosted.** Not a server. Scheduled workflows only run
  while the machine is awake.
- **Main workflow (`Invoice Automation - WhatsApp Delivery`) is deliberately
  inactive.** Twilio's free trial caps outbound WhatsApp at 5 messages/day and
  the Sandbox connection requires periodic re-join (see original
  `DEBUGGING_LOG.md`, entries 7–8). An always-on 2-hour schedule trigger
  against that tier wouldn't produce a working pipeline — it would produce a
  few successful sends followed by silent failures in the Executions tab
  until the cap resets or the sandbox is rejoined. Activation is gated on
  either a paid Twilio tier or completing the Meta Cloud API migration
  already planned, not on any remaining bug in this workflow.
