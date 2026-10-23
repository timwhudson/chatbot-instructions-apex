"""Grant field-level security (FLS) on the four skill-versioning fields.

WHY THIS SCRIPT EXISTS (same reason as grant_position_fls.py, which it copies)
  Fields deployed through the Metadata API get NO field-level security. If the
  LiteLLM proxy selects Version_Number__c / Version_Date__c / Bundle_Fingerprint__c
  before its integration user can read them, the WHOLE skill manifest query fails
  (the proxy serves its last-good manifest and every skill edit freezes). So this
  runs right after manifest/skill-versioning-fields.xml is deployed and BEFORE the
  proxy code that selects them ships.

WHAT IT DOES
  READ mirrors Reasoning_Effort__c's FieldPermissions parents (the house pattern
  on Chatbot_Instruction__c, incl. LiteLLM_CFO_Bot_Read_Only). EDIT:
    - Version_Number__c, Version_Date__c  -> nobody (the trigger owns them; the
      backfill runs as anonymous Apex, which FLS doesn't limit)
    - Bundle_Fingerprint__c               -> System Administrator only (pasted by
      an admin, or by Claude Code's publishing scripts as tim+1)
    - Created_From_Skill_ID__c            -> System Administrator only (the AI
      Committee launch step)
  Row inserts, never a Profile/PermissionSet metadata deploy (see
  grant_position_fls.py for why).

SAFETY
  Default DRY RUN. --apply inserts only missing rows, re-reads, and exits 1 on
  any failed insert, any planned row missing or different, any Edit outside the
  rules above, or LiteLLM_CFO_Bot_Read_Only unable to read all four fields.

RUN (from this repo's root, AFTER the metadata deploy):
  python3 scripts/grant_version_fls.py            # dry run
  python3 scripts/grant_version_fls.py --apply    # real grant + verify
Rollback: sf data delete record -s FieldPermissions -i <Id> -o tccfo-prod
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
# New field -> True when System Administrator may edit it (nobody else ever may).
NEW_FIELDS = {
    f"{OBJ}.Version_Number__c": False,
    f"{OBJ}.Version_Date__c": False,
    f"{OBJ}.Bundle_Fingerprint__c": True,
    f"{OBJ}.Created_From_Skill_ID__c": True,
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
    # Tooling CustomField lists a deployed field even before anyone has FLS on it.
    # (FieldDefinition does NOT: right after the 10-20 deploy it returned 0 rows for
    # both fields while the admin running this script had no FLS yet.)
    names = ",".join(f"'{f.split('.')[1].removesuffix('__c')}'" for f in NEW_FIELDS)
    out = subprocess.run(
        ["sf", "data", "query", "-o", ORG, "--use-tooling-api", "--json", "-q",
         "SELECT DeveloperName, TableEnumOrId FROM CustomField "
         f"WHERE DeveloperName IN ({names})"],
        capture_output=True, text=True, check=True,
    ).stdout
    rows = json.loads(out)["result"]["records"]
    # TableEnumOrId is the object's Id for a custom object; resolve ours to compare.
    obj_id = soql(f"SELECT DurableId FROM EntityDefinition WHERE QualifiedApiName = '{OBJ}'")[0]["DurableId"]
    # DurableId is the 15-character form of the 18-character TableEnumOrId.
    return {f"{OBJ}.{r['DeveloperName']}__c" for r in rows if r["TableEnumOrId"][:15] == obj_id[:15]}


# ── Step 2: build the plan from the source field's rows ──────────────
def build_plan():
    source = fls_rows([SOURCE_FIELD])
    existing = {(r["ParentId"], r["Field"]): r for r in fls_rows(NEW_FIELDS)}
    plan, skipped = [], []
    for src in source:
        for field, admin_edits in NEW_FIELDS.items():
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
                "PermissionsEdit": admin_edits and parent_label(src) == f"Profile: {ADMIN_PROFILE}",
                "_label": parent_label(src),  # stripped before sending
            })
    return source, plan, skipped


# ── Step 4: re-read and compare against the plan ─────────────────────
def verify(plan):
    """Return a list of problems (empty = verified)."""
    rows = fls_rows(NEW_FIELDS)
    by_key = {(r["ParentId"], r["Field"]): r for r in rows}
    by_label = {(parent_label(r), r["Field"]): (r["PermissionsRead"], r["PermissionsEdit"]) for r in rows}
    problems = []

    # Every planned row exists with exactly the planned Read / Edit.
    for p in plan:
        r = by_key.get((p["ParentId"], p["Field"]))
        got = (r["PermissionsRead"], r["PermissionsEdit"]) if r else None
        if got != (p["PermissionsRead"], p["PermissionsEdit"]):
            problems.append(f"{p['_label']} -> {p['Field']}: planned "
                            f"{(p['PermissionsRead'], p['PermissionsEdit'])}, read back {got}")

    # Nobody but the admin profile may edit (covers rows that pre-existed too).
    for (label, field), (_, edit) in by_label.items():
        if edit and not (label == f"Profile: {ADMIN_PROFILE}" and NEW_FIELDS.get(field)):
            problems.append(f"{label} -> {field}: has Edit, which these rules never grant it")

    # The grants the proxy and admins depend on, printed for the record.
    checks = [(f"PermSet: {PROXY_PERMSET}", field, lambda p: p[0]) for field in NEW_FIELDS] + [
        (f"Profile: {ADMIN_PROFILE}", field, lambda p: p[0] and p[1]) for field, admin in NEW_FIELDS.items() if admin
    ]
    for parent, field, test in checks:
        perm = by_label.get((parent, field))
        passed = perm is not None and test(perm)
        print(f"  {'PASS' if passed else 'FAIL'}  {parent} -> {field.split('.')[1]} {perm}")
        if not passed:
            problems.append(f"{parent} -> {field}: required grant missing ({perm})")
    print(f"  rows now on the new fields: {len(rows)}")
    return problems


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
    must = {(f"PermSet: {PROXY_PERMSET}", f) for f in NEW_FIELDS} | {
        (f"Profile: {ADMIN_PROFILE}", f) for f, admin in NEW_FIELDS.items() if admin}
    covered = {(r["_label"], r["Field"]) for r in plan} | set(skipped)
    if not must <= covered:
        sys.exit(f"Plan is missing required grants: {must - covered}")

    if not APPLY:
        state = "NOT YET DEPLOYED: " + ", ".join(sorted(missing)) if missing else "all four fields deployed"
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
    problems = verify(plan)
    for problem in problems:
        print(f"  PROBLEM {problem}")
    if failed or problems:
        sys.exit("FLS verification FAILED: do not ship proxy code that selects these fields.")
    print("FLS verified. Next: the read check AS THE PROXY USER before the proxy ships.")


if __name__ == "__main__":
    main()
