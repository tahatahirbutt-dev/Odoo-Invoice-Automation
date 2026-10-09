# Deployment Status

## What is deployed today

- **Docker Compose stack on a laptop:** PostgreSQL 16, Odoo 17, n8n and a `cloudflared` container. It only runs while the machine is awake, so scheduled runs only happen then.
- **Public HTTPS via a Cloudflare named tunnel**, with two hostnames:
  - `hooks.` — public, and the tunnel forwards only `/webhook/invoice-pdf` and `/webhook/whatsapp-webhook`; every other path returns 404.
  - `n8n.` — the editor, behind a Cloudflare Access login.
- **Signed, expiring PDF links** protect the one data-bearing public endpoint (see `README.md`).
- **Twilio WhatsApp sandbox** for sending. The main workflow is committed **inactive** because the trial tier (5 messages/day, sandbox re-join) cannot support unattended scheduling.
- A Meta Cloud API **webhook-verification** workflow is active (verification only; sending still uses Twilio).

How it got here, including the dead ends: `DEPLOYMENT_LOG.md`.

## What is not deployed

- A server or VPS (an Azure/Oracle attempt was abandoned, see `DEPLOYMENT_LOG.md`, entries 1–2)
- Automated PostgreSQL backups
- n8n queue mode
- A dedicated Odoo API user with Invoicing-only access (the stack uses Odoo's `admin`)
- Sending through Meta's Cloud API (needs a permanent System User token)
- A Twilio status callback, so `sent` in the audit table means "accepted by Twilio", not "delivered"


No timeline: these get built when there is a real need (a client, or Project #3's scope).
