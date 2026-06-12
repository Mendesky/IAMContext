#!/usr/bin/env python3
"""One-off: derive PermissionKit's YAML fixture from OpportunityContext's openapi.yaml files.

READ-ONLY w.r.t. OpportunityContext. Mirrors OC's gen-permissions.py `classify()` so the fixture
reproduces exactly OC's 153 permissions — emitted in the SPLIT (Option B) shape: a `permissions:`
catalog + a `rules:` section (each rule requires its own permission, since OC is 1:1). Used only to
create the parity-test fixture; not part of the PermissionKit build.

Usage:  python3 scripts/oc_to_yaml.py <output.yaml> [OC_ROOT]
"""
import re, os, sys

OC = sys.argv[2] if len(sys.argv) > 2 else "/Users/abnertsai/JiaBao/Mendesky/OpportunityContext"
MODULES = [
    ("AuditQuotingAggregate", "AuditQuoting"),
    ("QuotingCaseGroupingAggregate", "QuotingCaseGrouping"),
    ("QuotationAggregate", "Quotation"),
    ("CompanyRegistrationQuotingAggregate", "CompanyRegistrationQuoting"),
    ("OpportunityContext", None),
]
SERVER_PREFIX = "/opportunity-context"

def parse_openapi(path):
    ops, cur, meth = [], None, None
    for line in open(path):
        m = re.match(r'^  (/\S*):\s*$', line)
        if m: cur, meth = m.group(1), None; continue
        m = re.match(r'^    (get|post|put|patch|delete):\s*$', line)
        if m: meth = m.group(1); continue
        m = re.match(r'^      operationId:\s*(\S+)', line)
        if m and cur and meth: ops.append((cur, meth, m.group(1))); meth = None
    return ops

def classify(agg, method, path):
    if agg is not None:
        return "Query" if method == "get" else agg
    if path.startswith("/files") or path.startswith("/images"): return "File"
    if method == "get": return "Query"
    return "Workflow"

entries = []
for mod, agg in MODULES:
    f = f"{OC}/Sources/{mod}/openapi.yaml"
    if not os.path.exists(f):
        sys.exit(f"MISSING {f}")
    for (path, method, op) in parse_openapi(f):
        entries.append((classify(agg, method, path), op, method, path))

# catalog: unique (slot, operationId) preserving first appearance (OC ops are unique → all kept)
catalog, seen = [], set()
for (slot, op, method, path) in entries:
    key = (slot, op)
    if key in seen: continue
    seen.add(key); catalog.append((slot, op))

out = []
out.append("# AUTO-DERIVED fixture from OpportunityContext openapi (read-only) — see scripts/oc_to_yaml.py.")
out.append("# OC's 153 permissions as a SPLIT (Option B) permission document: catalog + rules (here 1:1).")
out.append("context: OpportunityContext")
out.append(f"serverPrefix: {SERVER_PREFIX}")
out.append("permissions:")
for (slot, op) in catalog:
    out.append(f"  - slot: {slot}")
    out.append(f"    operationId: {op}")
out.append("rules:")
for (slot, op, method, path) in entries:
    out.append(f"  - method: {method}")
    out.append(f"    path: {path}")
    out.append(f"    requires:")
    out.append(f"      - {slot}.{op}")

dst = sys.argv[1]
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, "w").write("\n".join(out) + "\n")
print(f"wrote catalog={len(catalog)} rules={len(entries)} -> {dst}")
