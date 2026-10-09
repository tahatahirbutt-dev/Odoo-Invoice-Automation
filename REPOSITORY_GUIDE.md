# Repository Guide

Documentation
- `README.md` — status, architecture, security design, tests, known limitations
- `QUICKSTART.md` — step-by-step setup, test and troubleshooting
- `DEBUGGING_LOG.md` — workflow bugs, chronologically, with root causes
- `DEPLOYMENT_LOG.md` — infrastructure and deployment problems, with root causes
- `DEPLOYMENT.md` — what is deployed today and what is not
- `REPOSITORY_GUIDE.md` — this file
- `LICENSE` — MIT

Runtime
- `docker-compose.yml` — Postgres, Odoo, n8n and the Cloudflare tunnel; ports bound to 127.0.0.1
- `docker/initdb/00-databases-and-schema.sql` — first-start script: creates `n8n_db` and `invoice_automation_logs`, loads the schema
- `init.sql` — the `invoice_deliveries` audit table and summary view
- `.env.example` — every environment variable the stack reads
- `cloudflared/config.example.yml` — sanitized tunnel config (the real one lives in the gitignored `.cloudflared/`)
- `workflows/Invoice Automation - WhatsApp Delivery.json` — main workflow export
- `workflows/Serve Invoice PDFs.json` — signed-link PDF webhook export

Tests and CI
- `scripts/lint_workflows.py` — static rules for the workflow exports
- `tests/webhook_security.ps1` — live access-control test for the PDF webhook
- `.github/workflows/test-deploy.yml` — CI: lint, secret scan, docs check, fresh-database test
- `package.json` — convenience scripts (`npm test` runs the lint)
