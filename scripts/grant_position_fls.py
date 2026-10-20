"""Grant field-level security (FLS) on the two position-restriction fields.

WHY THIS SCRIPT EXISTS
  Fields deployed through the Metadata API get NO field-level security: nobody
  (including the LiteLLM proxy's integration user) can read them until a
  FieldPermissions row exists for each profile / permission set. If the proxy
  selects Allowed_Positions__c before its user can read it, the WHOLE skill
  manifest query fails (risk R1), so this runs right after the metadata deploy
  and BEFORE the proxy code that selects the field ships.

WHAT IT DOES
  Mirrors the FLS of an existing field on the same object, Reasoning_Effort__c,
  whose 31 FieldPermissions rows are the house pattern on Chatbot_Instruction__c
  (every field there has the same 31 parents: 29 profiles Read+Edit, and the
  permission sets LiteLLM_CFO_Bot_Read_Only and sfdc_slack Read-only).
    - Allowed_Positions__c       -> same Read / Edit as Reasoning_Effort__c
    - Is_Position_Restricted__c  -> same Read; Edit always false (formula fields
                                    are read-only; Salesforce rejects Edit=true)
  Editing records stays admin-only regardless: object-level Edit on
  Chatbot_Instruction__c is held only by System Administrator, System Admin
  Marketing and the Apex_Development permission set.

WHY ROW INSERTS (and not a Profile / PermissionSet metadata deploy)
  A FieldPermissions insert creates exactly one new row per parent per field and
  cannot touch any other permission. A Profile or PermissionSet metadata deploy
  sends that parent's permission document, and what happens to settings the file
  leaves out depends on the type and API version, so a partial file can reset
  unrelated permissions. Inserts are also what was used for the 10-18 library
  fields, PDFs_Sandbox_Only__c and the context-eviction fields.

SAFETY
  - Default is a DRY RUN: it reads only, prints the plan, and writes nothing.
  - --apply inserts ONLY rows that don't exist yet (existing rows are reported,
    never changed), then re-reads and checks the two rows that matter:
      LiteLLM_CFO_Bot_Read_Only: Read on both fields
      System Administrator:      Read+Edit on Allowed_Positions__c
  - No secrets: authentication is the local `sf` CLI's stored org login.

RUN (from this repo's root, AFTER the metadata deploy):
  python3 scripts/grant_position_fls.py            # dry run
  python3 scripts/grant_position_fls.py --apply    # real grant + verify
Rollback: delete the inserted rows (their Ids are printed), e.g.
  sf data delete record -s FieldPermissions -i <Id> -o tccfo-prod
"""
import json
import os
import subprocess
import sys
import tempfile

ORG = "tccfo-prod"
API = "/services/data/v65.0"
OBJ = "Chatbot_Instruction__c"
SOURCE_FIELD = f"{OBJ}.Reasoning_Effort__c"
# New field -> True when the field is a formula (Edit must be false).
NEW_FIELDS = {
    f"{OBJ}.Allowed_Positions__c": False,
    f"{OBJ}.Is_Position_Restricted__c": True,
}
PROXY_PERMSET = "LiteLLM_CFO_Bot_Read_Only"
ADMIN_PROFILE = "System Administrator"
APPLY = "--apply" in sys.argv


# ── Salesforce helpers (sf CLI; JSON in, JSON out) ───────────────────
def soql(query):
    cmd = ["sf", "data", "query", "-o", ORG, "-q", query, "--json"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return json.loads(out)["result"]["records"]


def rest_post(path, body):
    # Body goes through a private temp file (the CLI reads @file); removed after.
    fd, tmp = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(body, fh)
        r = subprocess.run(
            ["sf", "api", "request", "rest", API + path, "-X", "POST", "-o", ORG,
             "-b", "@" + tmp, "-H", "Content-Type:application/json"],
            capture_output=True, text=True,
        )
    finally:
        os.remove(tmp)
    if r.returncode != 0:
        sys.exit(f"POST {path} failed: {r.stderr.strip()[:500]}")
    return json.loads(r.stdout)


def parent_label(row):
    # "Profile: X" for a profile's hidden permission set, "PermSet: Name" otherwise.
    p = row["Parent"]
    if p.get("IsOwnedByProfile"):
        return "Profile: " + ((p.get("Profile") or {}).get("Name") or "?")
    return "PermSet: " + p["Name"]


def fls_rows(fields):
    names = ",".join(f"'{f}'" for f in fields)
    return soql(
        "SELECT Id, ParentId, Parent.Name, Parent.IsOwnedByProfile, Parent.Profile.Name, "
        "Field, PermissionsRead, PermissionsEdit FROM FieldPermissions "
        f"WHERE SobjectType = '{OBJ}' AND Field IN ({names})"
    )


# ── Step 1: the fields must exist (i.e. the metadata deploy happened) ─
def deployed_fields():
    # FieldDefinition is metadata, so it lists a field even before anyone has
    # FLS on it (a describe would hide it).
    names = ",".join(f"'{f.split('.')[1]}'" for f in NEW_FIELDS)
    rows = soql(
        "SELECT QualifiedApiName FROM FieldDefinition WHERE "
        f"EntityDefinition.QualifiedApiName = '{OBJ}' AND QualifiedApiName IN ({names})"
    )
    return {f"{OBJ}.{r['QualifiedApiName']}" for r in rows}


# ── Step 2: build the plan from the source field's rows ──────────────
def build_plan():
    source = fls_rows([SOURCE_FIELD])
    existing = {(r["ParentId"], r["Field"]): r for r in fls_rows(NEW_FIELDS)}
    plan, skipped = [], []
    for src in source:
        for field, is_formula in NEW_FIELDS.items():
            key = (src["ParentId"], field)
            if key in existing:
                skipped.append((parent_label(src), field))
                continue
            plan.append({
                "attributes": {"type": "FieldPermissions"},
                "ParentId": src["ParentId"],
                "SobjectType": OBJ,
                "Field": field,
                "PermissionsRead": src["PermissionsRead"],
                "PermissionsEdit": False if is_formula else src["PermissionsEdit"],
                "_label": parent_label(src),  # stripped before sending
            })
    return source, plan, skipped


# ── Step 4: verify the two grants that matter ────────────────────────
def verify():
    rows = fls_rows(NEW_FIELDS)
    got = {(parent_label(r), r["Field"]): (r["PermissionsRead"], r["PermissionsEdit"]) for r in rows}
    checks = [
        (f"PermSet: {PROXY_PERMSET}", f"{OBJ}.Allowed_Positions__c", lambda p: p[0]),
        (f"PermSet: {PROXY_PERMSET}", f"{OBJ}.Is_Position_Restricted__c", lambda p: p[0]),
        (f"Profile: {ADMIN_PROFILE}", f"{OBJ}.Allowed_Positions__c", lambda p: p[0] and p[1]),
    ]
    ok = True
    for parent, field, test in checks:
        perm = got.get((parent, field))
        passed = perm is not None and test(perm)
        ok &= passed
        print(f"  {'PASS' if passed else 'FAIL'}  {parent} -> {field.split('.')[1]} {perm}")
    print(f"  rows now on the new fields: {len(rows)} (expected {2 * len(fls_rows([SOURCE_FIELD]))})")
    return ok


def main():
    present = deployed_fields()
    missing = set(NEW_FIELDS) - present
    source, plan, skipped = build_plan()

    print(f"Source {SOURCE_FIELD}: {len(source)} parents "
          f"({sum(1 for s in source if s['PermissionsEdit'])} Read+Edit, "
          f"{sum(1 for s in source if not s['PermissionsEdit'])} Read-only)")
    for label, field in skipped:
        print(f"  already granted, left as is: {label} -> {field}")
    print(f"Rows to insert: {len(plan)}")
    for row in sorted(plan, key=lambda r: (r["Field"], r["_label"])):
        mode = "Read+Edit" if row["PermissionsEdit"] else ("Read" if row["PermissionsRead"] else "none")
        print(f"  {row['Field'].split('.')[1]:<28} {mode:<9} {row['_label']}")

    # The two grants the proxy and admins depend on must be in the plan or already present.
    must = {(f"PermSet: {PROXY_PERMSET}", f) for f in NEW_FIELDS} | {(f"Profile: {ADMIN_PROFILE}", f"{OBJ}.Allowed_Positions__c")}
    covered = {(r["_label"], r["Field"]) for r in plan} | set(skipped)
    assert must <= covered, f"plan is missing required grants: {must - covered}"

    if not APPLY:
        state = "NOT YET DEPLOYED: " + ", ".join(sorted(missing)) if missing else "both fields deployed"
        print(f"\nDRY RUN, nothing written ({state}). Re-run with --apply after the metadata deploy.")
        return
    if missing:
        sys.exit(f"Refusing to apply: fields not deployed yet: {sorted(missing)}")

    # ── Step 3: insert (composite, max 200 per call; partial success allowed
    # so one odd parent can't block the rest; failures are printed) ──
    inserted, failed = [], []
    for i in range(0, len(plan), 200):
        chunk = plan[i:i + 200]
        body = {"allOrNone": False, "records": [{k: v for k, v in r.items() if k != "_label"} for r in chunk]}
        for row, res in zip(chunk, rest_post("/composite/sobjects", body)):
            if res.get("success"):
                inserted.append(res["id"])
            else:
                failed.append((row["_label"], row["Field"], res.get("errors")))
    print(f"\nInserted {len(inserted)} rows: {', '.join(inserted)}")
    for label, field, errors in failed:
        print(f"  FAILED {label} -> {field}: {errors}")

    print("\nVerify:")
    if not verify():
        sys.exit("FLS verification FAILED: do not ship proxy code that selects these fields.")
    print("FLS verified. Next: the read check AS THE PROXY USER before the proxy ships.")


if __name__ == "__main__":
    main()
