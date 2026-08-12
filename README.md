# 📧 Odoo Invoice Automation – Automated PDF Delivery via WhatsApp

**A production-tested n8n system that detects posted invoices in Odoo ERP, fetches their PDFs live via a stateless webhook, and delivers them to customers over WhatsApp through Twilio — with a full PostgreSQL audit trail.**

![Status](https://img.shields.io/badge/Status-Working%20End--to--End-brightgreen)
![License](https://img.shields.io/badge/License-MIT-blue)
![n8n](https://img.shields.io/badge/n8n-latest-orange)
![Odoo](https://img.shields.io/badge/Odoo-17.0-red)
![Docker](https://img.shields.io/badge/Docker-Compose-blue)

---

## 🎯 Overview

This isn't a tutorial project — it's a working automation built and debugged against a real Odoo instance, with all the friction that involves (session auth quirks, Docker volume permission bugs, n8n expression-evaluation edge cases). The `DEBUGGING_LOG.md` in this repo documents that process in detail, because the troubleshooting is honestly as representative of the job as the finished workflow.

**What it does, end to end:**

1. **Trigger** → n8n runs on a schedule (cron), authenticates to Odoo via JSON-RPC
2. **Fetch** → Pulls all posted customer invoices (`account.move`, `move_type = out_invoice`, `state = posted`)
3. **Loop** → Processes each invoice individually (batch size 1, for clean error isolation)
4. **Generate PDF** → Authenticates a session cookie against Odoo, then fetches the invoice PDF live from Odoo's report engine — no PDFs are ever written to disk (see architecture note below on why)
5. **Get contact** → Fetches the customer's WhatsApp-capable phone number from their Odoo contact record, in parallel with the PDF fetch
6. **Filter** → Skips (and logs) any invoice whose customer has no valid mobile number, instead of failing the whole run
7. **Deliver** → Sends the invoice via Twilio WhatsApp API, with the PDF served through a second, independent n8n webhook workflow that Twilio fetches from directly
8. **Log** → Every outcome — sent or skipped — is written to a PostgreSQL audit table

**Business case:** replaces manual invoice-by-invoice WhatsApp sending with a scheduled, hands-off pipeline. For an SME sending even 20-30 invoices/week, this removes real recurring admin time and gives an auditable delivery record accountants actually want.

---

## 📊 System Architecture

This system is **two independent n8n workflows**, not one — that split is the key architectural decision, explained below.

```
┌────────────────────────────────────────────────────────────────────┐
│  WORKFLOW 1: Invoice Automation - WhatsApp Delivery                │
│                                                                      │
│  Schedule Trigger                                                  │
│       ↓                                                            │
│  Odoo Authenticate (JSON-RPC login → uid)                          │
│       ↓                                                            │
│  Fetch Unpaid/New Invoices (account.move search_read)              │
│       ↓                                                            │
│  Split Invoice Array → Loop Over Invoices (batch size 1)           │
│       ↓                                                            │
│  Get Odoo Session (session-cookie auth) → Extract Session ID       │
│       ↓                                                            │
│  ┌─────────────────────┐        ┌───────────────────────────┐     │
│  │ Fetch Invoice PDF    │        │ Get Customer Contact       │     │
│  │ (parallel branch)    │        │ (parallel branch)          │     │
│  └──────────┬───────────┘        └────────────┬────────────────┘   │
│             └──────────────┬────────────────────┘                  │
│                             ↓                                       │
│                  Merge PDF + Contact                                │
│                             ↓                                       │
│              Filter - Has Mobile Number?                            │
│              ┌──────────────┴──────────────┐                        │
│           YES↓                          NO ↓                        │
│    Format WhatsApp Number          Skipped - No Mobile Number       │
│              ↓                              ↓                       │
│      Send via Twilio (media_url        Log Skip to Postgres         │
│       points at Workflow 2)                                         │
│              ↓                                                      │
│    Log Delivery to Postgres                                         │
│              ↓                                                      │
│    (loops back to next invoice)                                     │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  WORKFLOW 2: Serve Invoice PDFs (stateless webhook)                 │
│                                                                      │
│  Webhook (GET /invoice-pdf?invoice_id=N)                            │
│       ↓                                                            │
│  Get Odoo Session → Extract Session ID                              │
│       ↓                                                            │
│  Fetch Invoice PDF (live, by invoice_id from query param)           │
│       ↓                                                            │
│  Respond to Webhook (binary PDF)                                    │
│                                                                      │
│  Exposed publicly via ngrok tunnel so Twilio's servers can fetch it. │
└────────────────────────────────────────────────────────────────────┘
```

### Why two workflows instead of one?

Twilio's WhatsApp API doesn't accept file attachments in the send request — it takes a `MediaUrl` and **fetches the file itself**, server-side, at send time. That means whatever URL you give it has to be publicly reachable and return the file live, independent of whatever n8n execution generated it.

The first version of this system tried to solve that by writing the PDF to a shared Docker volume and having Twilio fetch it via a "read file from disk" webhook. That approach hit a genuine, documented Node.js/Docker-on-Windows bug: `fs.access()`-based writability checks return false negatives on certain bind-mounted and named-volume configurations, even though the underlying write would succeed. Full details and every dead end are in `DEBUGGING_LOG.md`.

The fix was to **stop treating PDF generation as a one-time event and start treating it as a live, re-fetchable resource.** Workflow 2 doesn't care what Workflow 1 did — it independently re-authenticates to Odoo and re-renders the PDF fresh, every single time it's called. No shared state, no temp files, no cleanup, no permission edge cases. This is a stateless design and it's a legitimate pattern for exactly this class of problem (any time an external API needs to pull a file your system generates on demand).

---

## ⚙️ Technology Stack

| Component | Version | Purpose |
|---|---|---|
| **ERP Platform** | Odoo 17.0 (Community) | Source of invoice & customer data |
| **Automation Engine** | n8n (latest, self-hosted) | Workflow orchestration |
| **Database** | PostgreSQL 16 | n8n backend + invoice delivery audit log |
| **Messaging** | Twilio WhatsApp API (Sandbox) | PDF delivery channel |
| **Tunneling** | ngrok (static domain) | Exposes the local PDF-serving webhook publicly |
| **Containerization** | Docker Compose | All services on a shared bridge network |
| **API Integration** | Odoo JSON-RPC + session-cookie auth | Two separate Odoo auth flows (see below) |

**Why two different Odoo auth methods in the same system:** JSON-RPC `execute_kw` calls (searching/reading records) use a `uid` from a `login` call. Odoo's PDF report engine, however, only works through its web controller (`/report/pdf/...`), which requires a session cookie, not a `uid`. These are genuinely two separate authentication mechanisms inside Odoo itself — this project uses both, correctly, for the calls each one is actually meant for.

---

## 🚀 Setup

### Prerequisites
- Docker Desktop (with sufficient drive sharing enabled for bind mounts, if used)
- A Twilio account with WhatsApp Sandbox enabled, and a recipient number that has joined the sandbox
- ngrok account (free tier is sufficient)

### 1. Clone and configure environment

```bash
git clone https://github.com/Bindas69/Odoo-Invoice-Automation.git
cd Odoo-Invoice-Automation
cp .env.example .env
```

Edit `.env`:
```env
ODOO_USER=admin
ODOO_PASSWORD=admin
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> **Note on `N8N_BLOCK_ENV_ACCESS_IN_NODE`:** this project references `ODOO_USER`, `ODOO_PASSWORD`, and `TWILIO_ACCOUNT_SID` via `{{$env.VAR}}` expressions inside node parameters, rather than hardcoding them into committed workflow JSON. This requires `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` in `docker-compose.yml` (already set). Be aware: n8n has a known cosmetic bug where the expression editor shows a red "access to env vars denied" warning even when the value resolves correctly at execution time — confirmed via n8n's own GitHub issue tracker. Trust the **Execute step** output, not the inline preview.

The Twilio **Auth Token** is *not* stored as an env var — it's stored as an n8n credential (Basic Auth), referenced by the `Send via Twilio` node, which keeps it encrypted at rest and out of the workflow JSON entirely.

### 2. Start the stack

```bash
docker-compose up -d
```

This brings up PostgreSQL, Odoo, and n8n on a shared `invoice_network`. Odoo's Invoicing app needs to be installed manually on first run (Settings → Apps → search "Invoicing" → Install), and the admin user needs **Billing Administrator** access rights explicitly set (Settings → Users → Access Rights → Invoicing) — Odoo's UI can visually show a permission as set without it actually committing to the underlying access-control group, so verify this directly if you hit `AccessError` on `account.move`.

### 3. Start ngrok

```bash
ngrok http 5678
```

Copy the forwarding URL (e.g. `https://xxxx.ngrok-free.dev`) — this is what Workflow 1's `Format WhatsApp Number` node uses to build the `media_url` Twilio fetches from.

### 4. Import both workflows into n8n

Import `workflows/Invoice Automation - WhatsApp Delivery.json` and `workflows/Serve Invoice PDFs.json`. Update the ngrok URL inside `Format WhatsApp Number` to match your current tunnel (ngrok's free tier issues a new URL on restart unless you're on a static domain).

**Activate Workflow 2 first** (toggle "Active" — webhooks only respond when the workflow is saved and active, not just open in the editor), then test Workflow 1.

### 5. Verify

Run Workflow 1 manually. Check three things:
- The WhatsApp message actually arrives (confirms Twilio + the webhook fetch worked)
- Query the audit log:
```bash
docker exec -it postgres_invoice_automation psql -U odoo -d invoice_automation_logs \
  -c "SELECT * FROM invoice_deliveries ORDER BY created_at DESC LIMIT 5;"
```
- Confirm both `sent` and `skipped_no_phone` statuses appear correctly depending on test data

---

## 🐛 Real Bugs Hit While Building This

Full write-ups are in `DEBUGGING_LOG.md`. Summary, because this is genuinely useful signal for anyone evaluating this repo:

| Bug | Root Cause | Fix |
|---|---|---|
| Malformed n8n editor URL | `N8N_HOST` and `WEBHOOK_URL` both contained full URLs, got concatenated | `N8N_HOST` must be a bare hostname |
| `session_id=null` on every request | HTTP node wasn't configured to expose response headers | Enable "Include Response Headers and Status Code" |
| 403 on PDF fetch despite valid session | Wrong Odoo report technical name (`account.report_invoice` doesn't exist in this instance) | Correct name is `account.report_invoice_with_payments` |
| `AccessError` on `account.move` despite UI showing correct permissions | Odoo's Access Rights dropdown didn't commit to the real `res.groups` relation | Add the user from the group record directly, not the user form |
| IF filter broke on empty mobile field | Odoo returns boolean `false` (not `null`/`""`) for empty fields | Explicit normalization: `field !== false ? field : ''` |
| PDF file wouldn't write to disk | Node.js `fs.access()` writability check gives false negatives on Docker-Windows bind mounts | Abandoned disk writes entirely; switched to stateless webhook re-fetch |
| GitHub Push Protection blocked commit | Twilio Account SID hardcoded directly in a node's URL field | Replaced with `{{$env.TWILIO_ACCOUNT_SID}}` expression |

---

## 📊 Database Schema

```sql
CREATE TABLE invoice_deliveries (
  id SERIAL PRIMARY KEY,
  invoice_id INTEGER NOT NULL,
  invoice_number VARCHAR(100) NOT NULL,
  customer_id INTEGER,
  customer_name VARCHAR(255),
  customer_phone VARCHAR(20) NOT NULL,
  delivery_channel VARCHAR(50) DEFAULT 'whatsapp',
  delivery_status VARCHAR(50) NOT NULL,   -- 'sent' | 'skipped_no_phone'
  attempt_count INTEGER DEFAULT 1,
  max_attempts INTEGER DEFAULT 3,          -- reserved for future retry logic
  sent_at TIMESTAMP,
  error_message TEXT,
  error_code VARCHAR(50),
  twilio_sid VARCHAR(100),                 -- Twilio message SID
  pdf_size INTEGER,                        -- PDF size in bytes
  response_time_ms INTEGER,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

The schema has a few columns the current workflow doesn't populate yet (`error_message`, `error_code`, `attempt_count`/`max_attempts` beyond their defaults) — they're there because the table was designed with retry logic in mind, which isn't built yet. `delivery_status` currently only ever holds two values in practice: `sent` or `skipped_no_phone`.

Query recent activity:
```sql
SELECT invoice_number, delivery_status, customer_phone, twilio_sid, sent_at
FROM invoice_deliveries
ORDER BY created_at DESC
LIMIT 10;
```

---

## 🛡️ Security Notes

- `.env` is gitignored; no credentials are committed
- Twilio Auth Token lives in n8n's encrypted credential store, never in workflow JSON
- Twilio Account SID and Odoo credentials are referenced via `{{$env.*}}` expressions rather than literals, so exported workflow JSON contains only variable *names*, never values
- Current setup uses Odoo's `admin/admin` for local dev — **not committed anywhere**, but also not appropriate for a real deployment; a production version would use a dedicated Odoo API user with only Invoicing-read access, not full admin

---

## 📈 What's Next

- **Project #2:** AI Customer Support Agent (n8n AI Agent node + Odoo Inventory JSON-RPC for real-time stock queries)
- **Project #3:** Production DevOps — migrate this stack to a live VPS with monitoring and alerting

---

## 📄 License

MIT License © 2026 Taha Tahir Butt

---

*Maintained by Taha Tahir Butt— Islamabad, Pakistan. Built and debugged against a real Odoo instance, not a tutorial sandbox.*
