#!/usr/bin/env python3
"""Static checks for the n8n workflow exports in workflows/. Standard library only.

Each rule exists because the bug it catches was actually hit in this project (see DEBUGGING_LOG.md).
Run:  python3 scripts/lint_workflows.py        (CI runs it on every push; exit code 1 = at least one failure)
"""
import json
import pathlib
import re
import sys

WF_DIR = pathlib.Path(__file__).resolve().parent.parent / "workflows"
MAIN = "Invoice Automation - WhatsApp Delivery.json"
SERVE = "Serve Invoice PDFs.json"
STICKY = "n8n-nodes-base.stickyNote"

failures = []


def fail(wf, rule, detail):
    failures.append(f"FAIL [{rule}] {wf}: {detail}")


def real_nodes(wf):
    return [n for n in wf["nodes"] if n["type"] != STICKY]


def strings(obj):
    if isinstance(obj, dict):
        for v in obj.values():
            yield from strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from strings(v)
    elif isinstance(obj, str):
        yield obj


def outputs(wf, name):
    return wf["connections"].get(name, {}).get("main", [])


def targets(wf, name):
    return [t["node"] for out in outputs(wf, name) for t in out]


def reachable(wf, start_names, stop_types=()):
    """Nodes reachable from start_names; does not walk past nodes whose type is in stop_types."""
    by_name = {n["name"]: n for n in wf["nodes"]}
    seen, stack = set(), list(start_names)
    while stack:
        name = stack.pop()
        if name in seen or name not in by_name:
            continue
        seen.add(name)
        if by_name[name]["type"] in stop_types:
            continue
        stack.extend(targets(wf, name))
    return seen


def check_common(name, wf):
    nodes = real_nodes(wf)
    names = {n["name"] for n in wf["nodes"]}
    for src, c in wf["connections"].items():
        if src not in names:
            fail(name, "graph", f"connection from unknown node '{src}'")
        for t in targets(wf, src):
            if t not in names:
                fail(name, "graph", f"'{src}' connects to unknown node '{t}'")

    entry = [n["name"] for n in nodes if n["type"] in ("n8n-nodes-base.scheduleTrigger", "n8n-nodes-base.webhook")]
    if not entry:
        fail(name, "graph", "no trigger node (schedule or webhook)")
    else:
        seen = reachable(wf, entry)
        for n in nodes:
            if n["name"] not in seen:
                fail(name, "graph", f"node '{n['name']}' is not reachable from a trigger")

    for n in nodes:
        # RULE expressions: a parameter containing {{ }} but not starting with '=' is sent LITERALLY.
        # (Real bug: Get Odoo Session sent the text "{{$env.ODOO_USER}}" as the login, Odoo answered with
        #  its login page and HTTP 200, and the "PDF" was HTML.)
        for s in strings(n["parameters"]):
            if "{{" in s and not s.startswith("="):
                fail(name, "expression", f"node '{n['name']}' has '{{{{' in a field that does not start with '=': {s[:50]!r}")

        # RULE credentials: nothing environment-specific or secret committed in node parameters.
        for s in strings(n["parameters"]):
            if re.search(r'"(password|login)"\s*:\s*"admin"', s) or re.search(r'^\s*"admin"\s*,?\s*$', s, re.M):
                fail(name, "credentials", f"node '{n['name']}' has a hardcoded admin credential")
            if "ngrok" in s.lower():
                fail(name, "credentials", f"node '{n['name']}' references an ngrok URL")
            if re.search(r"AC[0-9a-f]{32}", s) or re.search(r"EAA[A-Za-z0-9]{40,}", s):
                fail(name, "credentials", f"node '{n['name']}' contains what looks like a Twilio SID / Meta token")

        # RULE sql: queries must be parameterized ($1, $2 ...), never built with {{ }} interpolation.
        if n["type"] == "n8n-nodes-base.postgres" and n["parameters"].get("operation") == "executeQuery":
            q = n["parameters"].get("query", "")
            if "{{" in q:
                fail(name, "sql", f"node '{n['name']}' interpolates values into SQL; use $1.. with queryReplacement")
            if "$1" in q and "queryReplacement" not in n["parameters"].get("options", {}):
                fail(name, "sql", f"node '{n['name']}' uses $1 but has no queryReplacement")


def check_main(name, wf):
    nodes = {n["name"]: n for n in real_nodes(wf)}
    loops = [n for n in nodes.values() if n["type"] == "n8n-nodes-base.splitInBatches"]
    if len(loops) != 1:
        fail(name, "loop", f"expected exactly one Loop (splitInBatches) node, found {len(loops)}")
        return
    loop = loops[0]["name"]
    outs = outputs(wf, loop)
    body_starts = [t["node"] for t in outs[1]] if len(outs) > 1 else []
    if not body_starts:
        fail(name, "loop", "the loop output of the Loop node is not connected")
        return

    # RULE loop: every branch inside the loop must lead back to the Loop node.
    # (Real bug: 'Log Skip to Postgres' was a dead end, so one skipped invoice ended the whole run.)
    body = reachable(wf, body_starts, stop_types=())
    body.discard(loop)
    returns = False
    for n in body:
        node = nodes.get(n)
        if node is None:
            continue
        outs_n = outputs(wf, n)
        if not outs_n or all(len(o) == 0 for o in outs_n):
            fail(name, "loop", f"'{n}' is a dead end inside the loop; every branch must return to '{loop}'")
        for i, o in enumerate(outs_n):
            if len(o) == 0:
                fail(name, "loop", f"output {i} of '{n}' is not connected")
        if loop in targets(wf, n):
            returns = True
        if node.get("onError") == "continueErrorOutput" and (len(outs_n) < 2 or len(outs_n[1]) == 0):
            fail(name, "loop", f"'{n}' continues on error but its error output is not connected (failures would vanish)")
    if not returns:
        fail(name, "loop", f"nothing inside the loop connects back to '{loop}'")

    # RULE dedupe: the invoice query must exclude invoices already sent.
    # (Real bug: every run re-sent every posted invoice.)
    found = any("account.move" in s and '"not in"' in s
                for n in nodes.values() for s in strings(n["parameters"]))
    if not found:
        fail(name, "dedupe", "no Odoo account.move query with an [\"id\", \"not in\", ...] filter")

    # RULE signed links: the media URL sent to Twilio must carry exp + token.
    urls = [s for n in nodes.values() for s in strings(n["parameters"]) if "/webhook/invoice-pdf" in s]
    if not urls:
        fail(name, "signed-link", "no node builds the /webhook/invoice-pdf media URL")
    for u in urls:
        if "token=" not in u or "exp=" not in u:
            fail(name, "signed-link", "media URL does not include exp= and token=")


def check_serve(name, wf):
    nodes = real_nodes(wf)
    hooks = [n["name"] for n in nodes if n["type"] == "n8n-nodes-base.webhook"]
    if len(hooks) != 1:
        fail(name, "webhook-gate", f"expected exactly one Webhook node, found {len(hooks)}")
        return
    # RULE webhook-gate: no HTTP request to Odoo may be reachable from the webhook without passing an IF check.
    # (Real bug: the endpoint was public and unauthenticated; any invoice_id returned that customer's invoice.)
    ungated = reachable(wf, [hooks[0]], stop_types=("n8n-nodes-base.if",))
    by_name = {n["name"]: n for n in wf["nodes"]}
    for n in ungated:
        if by_name[n]["type"] == "n8n-nodes-base.httpRequest":
            fail(name, "webhook-gate", f"'{n}' (HTTP request) is reachable from the webhook without passing an IF check")
    if not any(by_name[n]["type"] == "n8n-nodes-base.if" for n in ungated):
        fail(name, "webhook-gate", "no IF node validates the request before Odoo is called")


def main():
    checks = {MAIN: check_main, SERVE: check_serve}
    for fname, specific in checks.items():
        path = WF_DIR / fname
        if not path.exists():
            failures.append(f"FAIL [files] missing workflow export: workflows/{fname}")
            continue
        try:
            wf = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            failures.append(f"FAIL [json] {fname}: {e}")
            continue
        check_common(fname, wf)
        specific(fname, wf)
        print(f"checked {fname}: {len(real_nodes(wf))} nodes")

    if failures:
        print()
        print("\n".join(failures))
        print(f"\n{len(failures)} problem(s) found")
        return 1
    print("all workflow checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
