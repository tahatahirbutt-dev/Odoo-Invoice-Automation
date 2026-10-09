# 📧 Odoo Invoice Automation – PDF Delivery via WhatsApp

**An n8n system that finds posted invoices in Odoo, sends each customer their invoice PDF over WhatsApp (Twilio), and records every outcome in a PostgreSQL audit table.**

![Status](https://img.shields.io/badge/Status-Working%20demo%20(laptop--hosted)-yellow)
![License](https://img.shields.io/badge/License-MIT-blue)
![n8n](https://img.shields.io/badge/n8n-self--hosted-orange)
![Odoo](https://img.shields.io/badge/Odoo-17.0-red)
![Docker](https://img.shields.io/badge/Docker-Compose-blue)

---

## 🎯 Status — read this first

| | |
|---|---|
| **What is verified** | On 2026-10-08 the current workflows delivered a real invoice PDF to a real WhatsApp number through the Twilio sandbox, via the public Cloudflare tunnel, with the audit row written. Earlier fixes were verified step by step (see `DEBUGGING_LOG.md`). |
| **What it is not** | Not a production deployment. It runs in Docker on a laptop (only while the machine is awake), messages go through a Twilio **trial sandbox** (5 messages/day, recipients must join the sandbox), and the main workflow is committed **inactive** for that reason. |
| **Not yet exercised** | The failed-send branch (built, but no failure has occurred since it was added) and an apostrophe in a customer name (the schema accepts it — checked in CI — but the n8n parameterized insert has not been run with one). |

This is a portfolio project built and debugged against a real Odoo instance. The two logs record the bugs honestly, including the ones found after the first version "worked".

---

## ⚙️ What it does

1. **Trigger** – n8n runs on a schedule (every 2 hours) and logs in to Odoo over JSON-RPC.
2. **Skip what was already sent** – reads the audit table and excludes every invoice that already has a `sent` row.
3. **Fetch** – gets posted customer invoices (`account.move`, `out_invoice`, `posted`) not in that list.
4. **Loop** – one invoice at a time, so a problem with one invoice cannot affect the others. Every branch returns to the loop.
5. **Contact** – reads the customer's **Mobile** field from Odoo. (`Phone` is ignored on purpose: it is often a landline or a number without a country code.)
6. **Filter** – no usable mobile number → logged as `skipped_no_phone`, and the run continues.
7. **Sign the link** – builds a PDF link valid for 1 hour, signed with HMAC-SHA256 (see below).
8. **Send** – Twilio WhatsApp API, with `MediaUrl` pointing at the signed link.
9. **Log** – `sent`, `skipped_no_phone` or `failed` is written to PostgreSQL. A failed send goes to its own branch and the run continues.

**Business case:** replaces sending invoices one by one by hand with a scheduled pipeline and an audit record accountants can query.

---

## 📊 Architecture

Two independent n8n workflows:

```
WORKFLOW 1: Invoice Automation - WhatsApp Delivery (schedule, every 2 h)

 Schedule → Get Sent Invoice IDs (Postgres) → Odoo Authenticate → Fetch Unsent Invoices
   → Split Invoice Array → Loop Over Invoices (batch size 1) ◄─────────────────────────┐
        → Get Customer Contact → Filter - Has Mobile Number                             │
              │ yes                               │ no                                  │
              ▼                                   ▼                                     │
        Format WhatsApp Number              Skipped → Log Skip to Postgres ─────────────┤
              → Sign PDF Link (HMAC)                                                    │
              → Build Media URL                                                         │
              → Send via Twilio ──ok──→ Log Delivery to Postgres ───────────────────────┤
                       └──error──→ Log Failure to Postgres ─────────────────────────────┘

WORKFLOW 2: Serve Invoice PDFs (webhook GET /webhook/invoice-pdf?invoice_id&exp&token)

 Webhook → Compute Expected Token (HMAC) → Link Valid?
              │ yes: id is 1-9 digits, not expired, token matches
              ▼
        Get Odoo Session → Extract Session ID → Fetch Invoice PDF → Respond (PDF)
              │ no
              ▼
        Reject 403   (Odoo is never contacted)
```

### Why two workflows

Twilio's WhatsApp API does not take file attachments. It takes a `MediaUrl` and **fetches the file itself**, at send time, from the public internet. So the PDF has to be available at a URL independent of the execution that sent the message.

An early version wrote PDFs to a Docker volume. That hit a Node.js/Docker-on-Windows bug (`fs.access()` false negatives on mounted volumes). The fix was to stop storing PDFs: Workflow 2 re-authenticates to Odoo and renders the invoice fresh on every request. No files, no cleanup, no shared state. The cost is one Odoo render per fetch (about 4–5 seconds here).

### Signed PDF links (access control)

The PDF endpoint has to be reachable by Twilio, so it is public. Invoice IDs are guessable, so the link itself proves permission:

```
https://<PUBLIC_BASE_URL>/webhook/invoice-pdf?invoice_id=12&exp=1791441568&token=<hex>
token = HMAC-SHA256(key = PDF_LINK_SECRET, message = "<invoice_id>.<exp>")
```

Workflow 2 rejects (HTTP 403, before touching Odoo) a request that has a malformed id, an expired `exp`, or a wrong token. The id must be 1–9 digits, because Odoo's report URL accepts comma-separated ids and would otherwise return several invoices in one PDF. Links last one hour. The token comparison is not constant-time (n8n expressions cannot do that); over a public tunnel this is a theoretical concern only.

`tests/webhook_security.ps1` checks seven cases against the live stack: valid link, no signature, token for another invoice, expired, one wrong character, comma-separated ids, non-numeric id.

### Public exposure

| Hostname | Who uses it | What is reachable |
|---|---|---|
| `hooks.<your domain>` | Twilio, Meta | Only `/webhook/invoice-pdf` and `/webhook/whatsapp-webhook`. Everything else (including `/`, `/signin`, `/healthz`) returns 404 from the tunnel itself. |
| `n8n.<your domain>` | You | The n8n editor, behind a **Cloudflare Access** login (configured in the Cloudflare dashboard, not in this repo). |

The tunnel rules are in `cloudflared/config.example.yml`. Docker publishes Postgres, Odoo and n8n on `127.0.0.1` only.

### Two Odoo authentication methods

JSON-RPC `execute_kw` calls (search, read) authenticate with a `uid` from `login`. Odoo's PDF report engine is only reachable through its web controller (`/report/pdf/...`), which needs a **session cookie**. This project uses each one for the calls it is meant for.

---

## ⚙️ Technology Stack

| Component | Version | Purpose |
|---|---|---|
| ERP | Odoo 17.0 (Community) | Source of invoices and customers |
| Automation | n8n (self-hosted) | Workflow orchestration |
| Database | PostgreSQL 16 | Odoo, n8n and the delivery audit log (three databases) |
| Messaging | Twilio WhatsApp API (sandbox) | PDF delivery |
| Tunnel | Cloudflare Tunnel (named) | Public HTTPS without port forwarding |
| Containers | Docker Compose | Postgres, Odoo, n8n, cloudflared |
| CI | GitHub Actions | Workflow lint, secret scan, fresh-database test |

---

## 🚀 Setup

Full step-by-step guide: **[QUICKSTART.md](QUICKSTART.md)**. In short:

1. `cp .env.example .env` and fill it in (generate `PDF_LINK_SECRET` with `openssl rand -hex 32`).
2. `docker compose up -d` — on a fresh volume this also creates `n8n_db` and `invoice_automation_logs` and loads the schema.
3. Install Odoo's Invoicing app, grant Billing Administrator, set a **Mobile** number on a test customer.
4. Create a Cloudflare tunnel with the two hostnames, using `cloudflared/config.example.yml`.
5. Import both workflows. Activate **Serve Invoice PDFs** first.
6. Run **Invoice Automation - WhatsApp Delivery** manually and check the audit table.

The main workflow is committed inactive. Activate it only on a paid Twilio tier (or after moving to Meta's Cloud API); on the trial tier a 2-hour schedule would hit the daily cap and then fail silently.

---

## ✅ Testing

| What | How | Where |
|---|---|---|
| Workflow rules: every branch returns to the loop, the PDF webhook is gated, no `{{ }}` without `=`, no hardcoded credentials, SQL is parameterized, invoice query excludes sent invoices, media URL is signed | `python3 scripts/lint_workflows.py` | CI, every push |
| Fresh clone: databases and schema are created on an empty volume; the schema accepts the rows the workflow writes | `docker compose up -d postgres` + `psql` | CI, every push |
| Webhook access control against the live stack | `.\tests\webhook_security.ps1` | Manual (needs the stack) |
| End to end (Odoo → n8n → Twilio → WhatsApp) | Run the workflow, check the phone and the audit table | Manual |

The lint rules were each checked by re-introducing the original bug and confirming the lint fails.

---

## 🐛 Real bugs hit while building this

Details, symptoms and root causes: `DEBUGGING_LOG.md` (workflows) and `DEPLOYMENT_LOG.md` (infrastructure).

| Bug | Root cause | Fix |
|---|---|---|
| Odoo returns HTTP 200 with the login page instead of an error | Session cookie missing, then (later) the login body was sent unevaluated | Enable response headers; `=` prefix on the expression; tests assert `application/pdf`, not just 200 |
| `403` on the PDF despite a valid session | Wrong report name | `account.report_invoice_with_payments` |
| `AccessError` on `account.move` with the right UI setting | Odoo's dropdown did not commit the group | Add the user from the group record |
| Empty mobile field passed the filter | Odoo uses `false`, not `null` | Normalize `false` to `''` before the check |
| PDF would not write to disk | `fs.access()` false negatives on Docker-Windows volumes | Stateless re-fetch webhook |
| **One skipped invoice ended the run** | The skip log node had no connection back to the loop | Every branch returns to the loop |
| **Every run re-sent every posted invoice** | Query had no memory of what was sent | Exclude invoices with a `sent` row |
| **PDF endpoint public and unauthenticated** | Sequential invoice ids, no check | HMAC-signed, expiring links; id format check |
| **Twilio said `queued`, nothing arrived** | Cloudflare Access redirected Twilio's PDF fetch to a login page | Separate public hostname with path-restricted tunnel rules |
| Audit rows had an empty phone and no Twilio SID | Log node read the Twilio response, not the earlier item | Read from the right node; store plain E.164 |

---

## 📊 Database schema

Database `invoice_automation_logs`, table `invoice_deliveries` (full DDL and a daily summary view in `init.sql`):

| Column | Written by the workflow | Notes |
|---|---|---|
| `invoice_id`, `invoice_number` | yes | |
| `customer_id`, `customer_name` | yes | |
| `customer_phone` | yes | E.164 without the `whatsapp:` prefix; `''` when skipped |
| `delivery_status` | yes | `sent` (accepted by Twilio — **not** proof of delivery), `skipped_no_phone`, `failed` |
| `twilio_sid` | `sent` rows | |
| `error_message` | `failed` rows | |
| `sent_at`, `created_at`, `updated_at` | yes | |
| `attempt_count`, `max_attempts`, `error_code`, `pdf_size`, `response_time_ms` | no | Reserved for retry logic / metrics that are not built |

```sql
SELECT invoice_number, delivery_status, customer_phone, twilio_sid, error_message
FROM invoice_deliveries ORDER BY created_at DESC LIMIT 10;
```

---

## 🛡️ Security notes

- `.env` is gitignored. The Twilio **Auth Token** is not in `.env` at all; it lives in an n8n credential (encrypted at rest).
- Workflow JSON references secrets only as `{{$env.NAME}}`, never as values. The lint checks this.
- **Local-dev defaults are committed, on purpose:** the Postgres password (`odoopass123`) in `docker-compose.yml` and `.env.example`, and Odoo's `admin` / `admin` in the docs. They protect a local stack whose ports are bound to `127.0.0.1`. They must be changed before this runs anywhere else; a production setup would also use a dedicated Odoo API user with Invoicing access only.
- The public hostname exposes two webhook paths and nothing else; the editor sits behind Cloudflare Access.
- Anything that appears in a screenshot or an upload should be treated as exposed and rotated (see `DEPLOYMENT_LOG.md`, entry 9).

---

## ⚠️ Known limitations

- **`sent` means Twilio accepted the message, not that WhatsApp delivered it.** A Twilio status callback would close this; not built.
- **Skipped invoices are logged again on every run** (they stay eligible so they send once a number is added). The audit table grows by one row per skipped invoice per run.
- **No automatic retry.** A failed or skipped invoice is simply tried again on the next run; only `sent` invoices are excluded.
- **Laptop-hosted**, so scheduled runs only happen while the machine is awake.
- **Twilio sandbox / trial limits** apply; sending through Meta's Cloud API is planned but not migrated (the webhook-verification workflow exists; the token in use is temporary).
- **CI is static plus a database test.** It does not run Odoo or n8n; the live checks are manual.
- Rendering a PDF takes about 4–5 seconds per request.

---

## 📈 What's Next

- **Project #2:** AI Inventory Assistant — n8n AI Agent + Odoo Inventory over WhatsApp ([complete](https://github.com/tahatahirbutt-dev/Odoo-AI-Assistant))
- **Project #3:** Automated payment reminders — staged WhatsApp reminders for overdue invoices, reusing this stack
- Twilio status callback so the audit log records real delivery

---

## 📄 License

MIT License © 2026 Taha Tahir Butt

---

*Maintained by Taha Tahir Butt — Islamabad, Pakistan.*
