# Technical Journal — Serve Invoice PDFs Webhook & End-to-End WhatsApp Delivery

> **How to read this file.** Part 1 (July 2026) is the original build: bugs 1–8. Part 2 (October 2026) is
> what turned up when the working system was re-read and re-tested against the real stack: bugs 9–13.
> Infrastructure problems (tunnel, Cloudflare Access, compose, fresh-clone startup) are in `DEPLOYMENT_LOG.md`.
> For the current design, see `README.md`.

This log documents the debugging process behind Project #1's second workflow
(**Serve Invoice PDFs**) and the final end-to-end integration with the main
**Invoice Automation — WhatsApp Delivery** workflow. It's included deliberately:
the troubleshooting process below reflects the actual day-to-day work of
building automation systems against real, imperfect APIs — and is arguably more
representative of the job than the finished workflow diagram alone.

## Summary

Built a second, stateless n8n workflow (`Serve Invoice PDFs`) whose only job is
to fetch a single invoice PDF from Odoo on demand via a public webhook. This
decouples PDF *generation* from PDF *delivery*: Twilio calls the webhook at
message-send time and always gets a freshly-rendered PDF, rather than n8n
needing to host static files anywhere.

Wired this into the main workflow so that Twilio's WhatsApp API fetches the
invoice PDF live through a public tunnel (ngrok at the time; a Cloudflare named
tunnel since — see `DEPLOYMENT_LOG.md`), completing the July pipeline. This
diagram is the **original** flow, kept for the history; the current one is in
`README.md` (the PDF is no longer fetched in this workflow, and every branch
returns to the loop):

```
Schedule Trigger → Odoo Authenticate → Fetch Unpaid/New Invoices
  → Split Invoice Array → Loop Over Invoices → Get Odoo Session
  → Extract Session ID → Fetch Invoice PDF → Get Customer Contact
  → Merge PDF + Contact → Filter (Has Mobile Number) → Format WhatsApp Number
  → Send via Twilio
```

## Bugs found and fixed (chronological)

### 1. Duplicated protocol/port in n8n's self-reported URL
**Symptom:** Browser showed `DNS_PROBE_FINISHED_NXDOMAIN`; n8n logs showed
`Editor is now accessible via: http://http://localhost:5678:5678`.
**Cause:** Two n8n environment variables (`N8N_HOST` / `WEBHOOK_URL`) each
already contained a full `http://host:port` string, so n8n concatenated them
into a malformed URL. This also caused the container's healthcheck to fail
(`docker ps` showed `unhealthy`).
**Fix:** Ensure `N8N_HOST` is a bare hostname with no protocol/port, and
`WEBHOOK_URL` is the only field carrying the full URL.

### 2. Missing response headers broke session-cookie extraction
**Symptom:** "Extract Session ID" node produced `null`; every downstream
request sent a broken `Cookie: session_id=null` header. Odoo silently
redirected to `/web/login` and returned **HTTP 200** with login-page HTML
instead of an error — so n8n had no way to detect the failure automatically.
**Cause:** The "Get Odoo Session" HTTP Request node wasn't configured to
return response headers, only the JSON body.
**Fix:** Enabled **Options → Response → Include Response Headers and Status
Code**, which exposes `headers['set-cookie']` for the session ID to be
extracted from.

### 3. Malformed Cookie header (duplicate prefix + wrong field reference)
**Symptom:** Same login-redirect behavior even after fix #2.
**Cause:** The header Value field contained a literal, redundant `Cookie:`
prefix (the header **Name** field already supplies that), and referenced a
non-existent field (`session_id` instead of the actual field name
`session_cookie`).
**Fix:** Header Value set to exactly `{{ $json.session_cookie }}` — no manual
prefix, correct field name.

### 4. Wrong Odoo report technical name
**Symptom:** Odoo returned `403 Forbidden — perhaps check your credentials?`
even with a valid session cookie.
**Cause:** The workflow used `account.report_invoice`, which does not exist
as a registered report action in this Odoo 17 instance. The correct
technical name is **`account.report_invoice_with_payments`** — a naming
change from older Odoo versions (12–14 commonly used `report_invoice`).
**Fix:** Updated the report URL in both the Serve Invoice PDFs workflow and
the main workflow's Fetch Invoice PDF node.
**Lesson:** A confirmed valid session + a wrong report name still produces a
403, not a clear "report not found" error — worth checking report names
directly against Odoo's `ir.actions.report` model when this happens, rather
than assuming it's an auth problem.

### 5. Odoo UI permission dropdown didn't sync to the real access-control group
**Symptom:** `Fetch Unpaid/New Invoices` failed with
`odoo.exceptions.AccessError: You are not allowed to access 'Journal Entry'
(account.move) records`, even though the authenticating user (Mitchell
Admin, uid 2) showed **"Billing Administrator"** selected in
Settings → Users → Access Rights.
**Cause:** The friendly dropdown selection had not actually been committed to
the user's real `res.groups` membership. Checking the user's raw technical
groups (Developer Mode → Users & Companies → Groups) confirmed
`Invoicing / Billing Administrator` was genuinely absent from the list,
despite the UI implying otherwise.
**Fix:** Opened the **group record itself** (Settings → Users & Companies →
Groups → "Invoicing / Billing Administrator") and added the user directly
from that side, rather than via the user form's dropdown. This forced the
underlying relation to commit correctly.
**Lesson:** When an Odoo API call is rejected despite the UI showing correct
permissions, verify the user's actual group membership directly — the
simplified Access Rights dropdown can visually desync from the backing data.

### 6. IF node "is not empty" check broken by boolean field values
**Symptom:** `Filter - Has Mobile Number` node errored:
`Wrong type: 'false' is a boolean but was expecting a string`.
**Cause:** Odoo represents an empty field as the boolean `false`, not `null`
or `""`. n8n's strict-mode string comparison rejected the type mismatch.
**Partial fix (introduced a second bug):** Enabling "Convert types where
required" resolved the type error, but caused n8n to coerce the boolean
`false` into the *string* `"false"` before the emptiness check — and a
5-character string is not empty, so contacts with no real mobile number
incorrectly passed the filter.
**Final fix:** Explicit expression to normalize Odoo's `false` placeholder to
a real empty string before the check:
```
{{ $json.result[0].mobile && $json.result[0].mobile !== false ? $json.result[0].mobile : '' }}
```
**Lesson:** Odoo's JSON-RPC layer uses `false` as a universal "no value"
sentinel across field types (not just booleans) — any filter logic touching
raw Odoo field values needs to account for this explicitly.

### 7. Twilio WhatsApp Sandbox — join expiry
**Symptom:** Message API call succeeded (`status: "queued"`, PDF media
attached correctly) but never arrived on WhatsApp. Twilio's message log
showed **Error 63015**: *"Channel Sandbox can only send messages to phone
numbers that have joined the Sandbox."*
**Cause:** Twilio's WhatsApp Sandbox requires recipients to periodically
re-send a `join <keyword>` message; the connection lapses after a period of
inactivity.
**Fix:** Recipient re-sent the join code to the sandbox number.

### 8. Twilio trial-account daily message cap
**Symptom:** After rejoining the sandbox, the next send attempt returned
`The service is receiving too many requests from you — exceeded the 5 daily
messages limit`.
**Cause:** Twilio trial (non-upgraded) accounts are capped at 5 outbound
messages/day as an anti-abuse measure — a hard account-tier limit, unrelated
to the workflow itself.
**Status:** Confirmed as the final blocker; workflow build is functionally
complete. Awaiting daily reset (or account upgrade) to capture a final
successful delivery screenshot.

## Environment / operational notes

- **ngrok free tier (historical, replaced by Cloudflare Tunnel)**: session must stay running in its own terminal for the
  tunnel to stay reachable — if the terminal closes or the machine sleeps,
  the tunnel drops even though the static domain persists across restarts.
- **n8n webhook test vs. production URLs**: the Test URL (`/webhook-test/...`)
  only fires once per "Execute workflow" click and only while the canvas is
  open; the Production URL (`/webhook/...`) requires the workflow to be
  **Published/Active** and works continuously — this is what any real
  external caller (Twilio, etc.) must use.
- **git credential helper**: Windows Git's deprecated `manager-core` helper
  name was replaced with `manager` to fix push authentication.
- **`.gitignore`**: added `n8n_files/` to exclude Docker volume runtime data
  (may contain encrypted credentials/session state) from version control.

## Architecture decision: stateless webhook over disk-based PDF storage

Early in Project #1, a disk-write approach (saving PDFs to a shared Docker
volume, then referencing the file path) was abandoned after persistent
`fs.access()` false-negative behavior on Windows Docker volumes. The
**Serve Invoice PDFs** webhook workflow replaces this entirely: Twilio's
`media_url` points at a public endpoint that authenticates to Odoo and
renders the requested invoice fresh, on every call. This trades a small
amount of per-request latency for a much simpler, more resilient design with
no file-system state to manage or go stale.

---

# Part 2 — Hardening (October 2026)

Found by re-reading the exported workflows and running them against the real
stack, one change at a time. Most of these produced **no error at all**, which
is the point of writing them down.

### 9. One skipped invoice ended the whole run
**Symptom:** A customer with no mobile number was logged as `skipped_no_phone`
and the run stopped there; the remaining invoices were never processed. The
README said skips don't fail the run — that was only half true.
**Cause:** `Log Skip to Postgres` had no outgoing connection, and the only
node connected back to the loop was `Format WhatsApp Number` (the *send* path),
which also advanced the loop in parallel with the Twilio call. Found by reading
the connection graph, not by a failure.
**Fix:** Every branch ends at `Loop Over Invoices`: delivery log, skip log, and
a new failure log. `Send via Twilio` uses n8n's error output so a failed send
writes a `failed` row and the run continues. This also fixes the "failure
produces no audit row" gap listed in `DEPLOYMENT_LOG.md`.
**Verified:** A run over the demo data (3 Acme invoices with no mobile number,
1 sent) logged every invoice and finished (execution #662, 2026-10-07). The
`failed` branch is built but has not been exercised: no send has failed since.
**Lesson:** A loop is only as robust as its least-connected branch. Check every
output of every node inside it. `scripts/lint_workflows.py` now fails if any
branch inside the loop dead-ends.

### 10. Every run re-sent every posted invoice
**Symptom:** None. Found while reading the invoice query.
**Cause:** The query was `state = posted` with no memory of what had already
been sent, although the workflow's own note said "newly posted invoices". It
had gone unnoticed because the workflow had only ever been run by hand, and
the Twilio trial cap (5/day) would have hidden it anyway. Activated on a paid
tier it would have re-sent every invoice to every customer every 2 hours.
**Fix:** A `Get Sent Invoice IDs` Postgres node reads the ids that have a
`sent` row, and the Odoo domain gets `["id", "not in", [...]]`.
**Verified:** On the next run `sent_ids` held the previously sent invoice and
the split step produced 4 items out of 5 posted invoices.
**Lesson:** "Automation that runs on a schedule" needs an idempotency story
before it needs anything else. The audit table is now doing double duty as the
memory. If logging fails after a successful send, that invoice would be sent
again; that trade-off is accepted and documented.

### 11. The PDF webhook was public and unauthenticated
**Symptom:** None. `GET /webhook/invoice-pdf?invoice_id=N` returned that
invoice for anyone who asked, and Twilio needs the URL to be public, so it
could not simply be closed.
**Cause:** Insecure direct object reference: guessable ids and no proof of
permission. Worse, `invoice_id` went into Odoo's report URL unvalidated, and
that URL accepts comma-separated ids, so one request could likely return
several invoices (inferred from how the report controller works; not
demonstrated against this instance).
**Fix:** Links are signed. The main workflow adds `exp` (now + 1 hour) and
`token = HMAC-SHA256(PDF_LINK_SECRET, "<invoice_id>.<exp>")`. The webhook
workflow recomputes the token and requires: id is 1–9 digits, `exp` is in the
future, token matches. Anything else gets a 403 before Odoo is contacted.
**Verified** (locally and through the public hostname): valid link → `200
application/pdf`; no signature, a token for another invoice, an expired link,
and a comma-separated id signed with a valid token → all `403`. These are now
`tests/webhook_security.ps1`.
**Known limit:** the token comparison is not constant-time (n8n expressions
cannot do that); acceptable over a public tunnel, noted in the README.
**Lesson:** If a public URL has to exist, make the URL carry its own
authorization, and validate the shape of every input that reaches a downstream
system.

### 12. Odoo login sent as literal text — the "PDF" was a web page, HTTP 200
**Symptom:** A correctly signed request returned `200`, but the saved
`test.pdf` would not open and began with `<!DOCTYPE html>`.
**Cause:** In `Get Odoo Session` the JSON body started with `{`, not `=`, so
n8n treated it as plain text and sent the characters `{{$env.ODOO_USER}}` as
the login. Odoo rejected the login, issued an anonymous cookie anyway, and the
PDF request was redirected to the login page — the same silent failure as bug
#2. The earlier migration from literal credentials to `{{$env.*}}` (see
`DEPLOYMENT_LOG.md`, entry 12) was checked by reading the pushed file, not by
running the workflow, so the node looked right and was never evaluated.
**Fix:** `=` prefix on the body. Test cases now assert `Content-Type:
application/pdf`, not just the status code, and the lint fails on any field
that contains `{{ }}` without a leading `=`.
**Lesson:** A status code is not a result. Assert on the content, and verify a
config change by executing it, not by reading it.

### 13. Audit rows lost the phone and SID — and hid a column overflow
**Symptom:** `sent` rows had an empty `customer_phone` and a NULL
`twilio_sid`.
**Cause:** `Log Delivery to Postgres` read `whatsapp_to` from `$json`, but at
that point `$json` is Twilio's response, which has no such field, so the
expression fell back to `''`. The empty value was also hiding a second bug:
`customer_phone` is `VARCHAR(20)` and `whatsapp:+923001234567` is 22
characters, so fixing the first bug naively would have made every insert fail.
**Fix:** The log stores plain E.164 (`+923001234567`) taken from the format
node, `twilio_sid` from Twilio's `sid`, and now also `customer_id` and
`customer_name`. All three logging nodes use parameterized queries
(`$1, $2, …`) instead of string interpolation.
**Verified:** A `sent` row with the real number and a Twilio SID. CI inserts
all three row shapes, including a name with apostrophes, and asserts that the
prefixed form is rejected (`value too long for type character varying(20)`).
**Lesson:** When a field is always empty, find out why before filling it —
the emptiness may be covering for something else.

### 14. The failed-send branch had never run — first run found three more gaps
**Symptom:** None. The branch (`Send via Twilio` error output → `Log Failure to
Postgres` → back to the loop) was built in October but no send had failed since,
so it had never executed. I tested it on purpose with a customer whose Mobile
was `0300 1234567` (invoice `INV/2026/00006`), then ran the workflow twice.
**Result, run 1 (execution #674):** Twilio rejected the send with
`400 / code 21211: The 'To' number +03001234567 is not a valid phone number`.
The error output was taken, `Log Failure to Postgres` wrote a `failed` row
(id 30, with the Twilio error text and `customer_phone` = `+03001234567`), the
loop continued, and the three no-phone invoices after it were still processed.
The branch works.
**Result, run 2:** `INV/2026/00006` was fetched again and a second `failed` row
was written (id 34). Nothing stops a failed invoice from being retried on every
run.
**Gaps this exposed:**
1. **No phone normalization.** The workflow strips non-digits from Odoo's Mobile
   field and prepends `+`. A local-format number (`0300…`) becomes
   `+03001234567`, which is not valid E.164. Nothing validates the number
   before the send.
2. **Unbounded retry.** Only `sent` invoices are excluded from the next run, so
   an invoice that fails permanently (bad number) is re-sent every 2 hours
   forever, adding a `failed` row each time. The README called this "no
   automatic retry"; it is automatic, uncapped retry.
3. **Failures look like success.** Execution #674 shows **Succeeded** in the
   Executions list even though the send failed, because the error output is
   handled. The audit table is the only place the failure is visible, and
   nothing alerts anyone.
**Status:** Reproduced, not yet fixed. Planned: validate/normalize the number
before sending and log `skipped_invalid_phone`; stop retrying after N `failed`
rows; add an alert or a daily failed-count check.
**Not tested:** a Twilio rejection that arrives *after* acceptance (for example
63015 for a number that has not joined the sandbox). `sent` would still be
written for those, and no status callback exists to correct it.
**Lesson:** A branch that has never executed is a hypothesis, not a feature.
Testing it on purpose took 20 minutes and found three gaps that no amount of
reading the workflow showed.

### 15. Local-format phone numbers were sent to Twilio unchecked

**Symptom:** Found while testing entry 14. A customer Mobile of `0300 1234567`
became `+03001234567` and Twilio rejected it (`21211`, not a valid phone number).

**Cause:** `Format WhatsApp Number` stripped every non-digit from Odoo's Mobile
field and put `+` in front. That is only correct when the number already
includes its country code. A local number with a leading `0` produced an
invalid number, and nothing checked it before the send.

**Fix:** Two new nodes and one new log branch before the send. `Normalize Phone`
keeps `+…` as is, turns `00…` into `+…`, and replaces a single leading `0` with
`+` and `DEFAULT_COUNTRY_CODE` (an n8n environment variable; unset means a
leading-zero number is rejected rather than guessed). Anything else is treated
as already containing a country code. The result must match E.164
(`^\+[1-9]\d{7,14}$`), otherwise it is empty. `Valid Number?` sends empty
results to `Log Invalid Phone to Postgres`, which writes
`skipped_invalid_phone` with the raw value (first 100 characters) in
`error_message` and returns to the loop. `customer_phone` stays empty on that
row because the column is `VARCHAR(20)`; a long bad value there would make the
insert fail and stop the run.

**Verified:** The expression was run against 15 cases offline (local, `+`, `00`,
bracketed, UAE, unset country code, too short, letters, empty, `false`). Live
on the stack: Mobile `12345` produced a `skipped_invalid_phone` row (id 38,
`Invalid mobile: 12345`) with no Twilio call. Mobile `0319 0704800` produced a
`sent` row (id 42) for `+923190704800`, and the PDF arrived on the phone.

**Known gaps:** A number with no leading `0` and no `+` is assumed to include
its country code, so a UAE `501234567` becomes `+501234567`, which is wrong and
valid-looking. `skipped_invalid_phone` rows are re-logged on every run, like
`skipped_no_phone`. The failed-send retry cap (entry 14, gap 2) is not built.
The daily summary view has no column for the new status.

**Lesson:** Validate input before the call you cannot take back. Twilio's
rejection was a fine error message, but by then the invoice had already been
queued for retry every two hours.


### Related: Twilio said `queued`, nothing arrived
Not a workflow bug. Cloudflare Access was redirecting Twilio's PDF fetch to a
login page. See `DEPLOYMENT_LOG.md`, entry 13.
