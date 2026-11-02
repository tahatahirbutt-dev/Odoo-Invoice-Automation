#!/usr/bin/env bash
# Regression test for the "blank or weak PDF_LINK_SECRET fails open" gap.
# Needs the stack running with PDF_LINK_SECRET set to a deliberately bad value, e.g. PDF_LINK_SECRET=x
# (a blank value is refused by docker compose itself, so use a short non-empty value).
# The script signs a link with that same bad key. A correct workflow must still answer 403.
# Usage: SECRET=x ./tests/weak_secret.sh [base_url] [invoice_id]
set -euo pipefail
BASE="${1:-http://localhost:5678}"
ID="${2:-1}"
SECRET="${SECRET-}"
EXP=$(( $(date +%s) + 600 ))
TOKEN=$(python3 -c "import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())" "$SECRET" "$ID.$EXP")
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/webhook/invoice-pdf?invoice_id=$ID&exp=$EXP&token=$TOKEN")
if [ "$CODE" = "403" ]; then echo "PASS  link signed with a weak/blank key is rejected (got 403)"; else echo "FAIL  expected 403, got $CODE"; exit 1; fi
