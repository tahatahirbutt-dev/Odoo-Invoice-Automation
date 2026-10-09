# Quick Start Guide: Odoo Invoice Automation

Gets the system running locally. It deploys **two n8n workflows** (the second one is what lets Twilio fetch the PDF, so don't skip it) and, to actually deliver WhatsApp messages, a **public HTTPS hostname** that Twilio can reach.

Commands are shown for Git Bash/macOS/Linux; PowerShell equivalents are given where they differ.

---

## ✅ Pre-flight checklist

- [ ] Docker Desktop installed and running (Compose v2: the command is `docker compose`, with a space)
- [ ] A Twilio account with the WhatsApp Sandbox enabled, and a phone that has joined it (send `join <your-code>` to the sandbox number)
- [ ] A domain on Cloudflare (free plan is fine) and the `cloudflared` CLI, for the public hostname (Step 4)
- [ ] This repository cloned

---

## Step 1: Clone and configure

```bash
git clone https://github.com/tahatahirbutt-dev/Odoo-Invoice-Automation.git
cd Odoo-Invoice-Automation
cp .env.example .env          # PowerShell: Copy-Item .env.example .env
```

Edit `.env`:

| Variable | Value |
|---|---|
| `ODOO_USER` / `ODOO_PASSWORD` | `admin` / `admin` (local-dev defaults; Odoo's default login) |
| `TWILIO_ACCOUNT_SID` | Your Twilio Account SID (starts with `AC`) |
| `PUBLIC_BASE_URL` | Bare hostname for Twilio, e.g. `hooks.yourdomain.com` (no `https://`, no trailing slash) |
| `PDF_LINK_SECRET` | 64 hex characters, generated below |
| `N8N_DB_POSTGRESDB_*` | Leave as is (they match the local Postgres defaults in `docker-compose.yml`) |
| `META_*` | Leave empty unless you use the Meta webhook-verification workflow |

Generate the signing secret:

```bash
openssl rand -hex 32
```
```powershell
# PowerShell
$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
($b | ForEach-Object { $_.ToString('x2') }) -join ''
```

Your Twilio **Auth Token** does not go in `.env`; you enter it in n8n's credential store in Step 5, where it is encrypted.

The compose file has this project's hostnames in `N8N_HOST`, `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` (under the `n8n` service). Change those three to your own domain.

## Step 2: Start the stack

```bash
docker compose up -d postgres odoo n8n
docker compose ps
```

On a **fresh** volume, Postgres automatically creates `n8n_db` and `invoice_automation_logs` and loads the audit schema (`docker/initdb/` + `init.sql`). Odoo initializes its own database on first start, which takes a minute or two.

Check the audit table exists:

```bash
docker exec -it postgres_invoice_automation psql -U odoo -d invoice_automation_logs -c "\d invoice_deliveries"
```

> Upgrading an **existing** volume? The init script does not run again. Nothing is lost, and the schema is already there.

## Step 3: Set up Odoo

1. Open `http://localhost:8069` and log in with `admin` / `admin`.
2. **Install the Invoicing app**: Apps → search "Invoicing" → Install.
3. **Grant access rights** (skipping this causes a confusing `AccessError`): Settings → Users & Companies → Users → Administrator → Access Rights → **Invoicing: Billing Administrator**. If the error persists, add the user from the group record itself (Settings → Groups → Billing Administrator), because the dropdown can fail to commit.
4. **Have some posted invoices**: demo data may already include them; otherwise Invoicing → Customers → Invoices → New → Confirm. Only **posted** invoices are picked up.
5. **Set the Mobile field** on at least one test customer, in E.164 format with no spaces (e.g. `+923001234567`), using the number that joined your Twilio sandbox. The workflow reads **Mobile only**, not Phone.

## Step 4: Public hostname (Cloudflare Tunnel)

Twilio fetches the PDF from the public internet, so n8n must be reachable at `PUBLIC_BASE_URL`.

```bash
cloudflared tunnel login
cloudflared tunnel create invoice-automation
cloudflared tunnel route dns invoice-automation hooks.yourdomain.com
cloudflared tunnel route dns invoice-automation n8n.yourdomain.com
```

Create the `.cloudflared` folder in the repo root, put the generated `<TUNNEL_ID>.json` credentials file in it, copy `cloudflared/config.example.yml` to `.cloudflared/config.yml`, and replace the placeholders. (`.cloudflared/` is gitignored.)

The config exposes **only two paths** on the public `hooks.` host and gives everything else a 404. Check the rules before starting the tunnel:

```bash
docker compose run --rm --no-deps cloudflared tunnel ingress validate
docker compose run --rm --no-deps cloudflared tunnel ingress rule https://hooks.yourdomain.com/webhook/invoice-pdf   # expect: rule #0
docker compose run --rm --no-deps cloudflared tunnel ingress rule https://hooks.yourdomain.com/signin                # expect: http_status:404
docker compose up -d cloudflared
```

**Protect the editor:** in Cloudflare Zero Trust → Access controls → Applications, add a Self-hosted application for `n8n.yourdomain.com` with a policy that allows only you. Do **not** put Access in front of `hooks.`: Twilio cannot log in, and the signed links already protect the PDF path.

> No domain? A temporary tunnel (ngrok, or `cloudflared tunnel --url http://localhost:5678`) works for a short demo. Set `PUBLIC_BASE_URL` to its hostname. It exposes the whole n8n instance, so use it briefly and shut it down.

## Step 5: Import the workflows

Open n8n (`http://localhost:5678`, or your `n8n.` hostname).

**Import `Serve Invoice PDFs` first**, because the main workflow sends links that point at it:
1. New workflow → ⋯ → Import from file → `workflows/Serve Invoice PDFs.json`
2. **Save, then toggle Active.** A webhook only answers when the workflow is active, not just open in the editor.

**Then `Invoice Automation - WhatsApp Delivery`:**
1. Import `workflows/Invoice Automation - WhatsApp Delivery.json`.
2. Create credentials:
   - **Postgres**: host `postgres`, port `5432`, database `invoice_automation_logs`, user `odoo`, password = the local-dev default from `docker-compose.yml`.
   - **Basic Auth** for Twilio: username = your Account SID, password = your Auth Token.
3. Attach the Postgres credential to all four Postgres nodes (`Get Sent Invoice IDs`, `Log Delivery`, `Log Failure`, `Log Skip`) and the Twilio credential to `Send via Twilio`.
4. Leave it **inactive**. You can run it manually without activating it.

## Step 6: Test

**6a. The webhook's access control** (PowerShell, from the repo root; uses an invoice id that exists in Odoo):

```powershell
.\tests\webhook_security.ps1 -BaseUrl https://hooks.yourdomain.com -InvoiceId 1
```

Expect seven PASS lines. If the valid-link case says `200 text/html`, Odoo returned its login page: see Troubleshooting.

**6b. The full run.** Before running, send "hi" to the Twilio sandbox number from your phone (free-form messages are only allowed within 24 hours of your last message). Then run **Invoice Automation - WhatsApp Delivery** manually (Execute workflow) and watch: get sent ids → authenticate → fetch unsent invoices → loop → contact → filter → sign → send → log.

The PDF should arrive on your phone. Check the audit trail:

```bash
docker exec -it postgres_invoice_automation psql -U odoo -d invoice_automation_logs \
  -c "SELECT invoice_number, delivery_status, customer_phone, twilio_sid, error_message FROM invoice_deliveries ORDER BY created_at DESC LIMIT 10;"
```

Expect `sent` rows with a real phone and a `twilio_sid`, and `skipped_no_phone` rows for customers without a Mobile number. **Run it a second time:** invoices already `sent` must not be fetched again. (To resend one for testing: `DELETE FROM invoice_deliveries WHERE invoice_number = '...' AND delivery_status = 'sent';`.)

---

## 🐛 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Signed link returns `200 text/html` (the "PDF" is a web page) | Odoo login failed and returned its login page with HTTP 200 | Check `Get Odoo Session` output: `result.uid` must be a number. Make sure `ODOO_USER` / `ODOO_PASSWORD` reach the container (`docker compose exec n8n printenv ODOO_USER`) and that the JSON body field is in Expression mode (starts with `=`). |
| Every signed link returns `403` | `PDF_LINK_SECRET` differs between `.env` and the running container, or the link is expired | `docker compose up -d n8n` (compose only reads `.env` when the container is recreated); compare lengths, never print the secret |
| Public URL returns `302` to `cloudflareaccess.com` | A Cloudflare Access application covers the public hostname | Remove it from `hooks.`; keep Access on `n8n.` only |
| Public URL returns `404` | Path not in the tunnel's `path:` regex, or hostname not routed | `cloudflared tunnel ingress rule <url>`; check `tunnel route dns` ran |
| Twilio says `queued` but nothing arrives | Not delivered. Check the message in Twilio's log, or query its API | `63015` sandbox join expired (re-send `join <code>`); `63016` outside the 24 h window (send "hi" first); `63019` Twilio could not download the PDF (test the public URL) |
| Twilio "exceeded daily messages limit" | Trial cap: 5 messages/day | Wait for the reset or upgrade |
| `AccessError` on `account.move` | Billing Administrator not actually committed | Add the user from the group record (Step 3) |
| `session_id=null` / Odoo returns the login page | `Get Odoo Session` not returning headers | Enable "Include Response Headers and Status Code" |
| `403` from Odoo despite a valid session | Wrong report name | Must be `account.report_invoice_with_payments` |
| n8n restarts in a loop after a compose change | A database env var has the wrong name (n8n reads `DB_POSTGRESDB_USER` / `DB_POSTGRESDB_PASSWORD`) or `n8n_db` is missing | `docker compose logs n8n --tail 30` |
| `{{$env.*}}` shows a red "access denied" in the editor | Known cosmetic n8n bug | Ignore the preview; check the node's real output after executing |

For the full history of how each of these was found, see `DEBUGGING_LOG.md` and `DEPLOYMENT_LOG.md`.

---

## What's next

- `README.md`: architecture, the signed-link design and known limitations
- `DEPLOYMENT.md`: what is and isn't deployed
