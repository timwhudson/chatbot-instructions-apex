"""Read-only check, run AS THE LITELLM PROXY'S SALESFORCE USER, of the fields the
position-restriction feature reads (and, since skill versioning, the version fields).

WHY: the proxy's integration user only sees fields its profile / permission sets
grant. A field it can't read either vanishes from describe or makes a SOQL query
that names it fail (risk R1: the whole skill manifest query 400s). Running the
same auth helper the proxy uses proves what the proxy will actually see.

WHAT IT PRINTS (never credentials, emails, names or record content):
  1. Contact: whether Email, Status__c, Current_Position__c are visible, and the
     row count for the staff-directory filter (Active Employee with an email).
  2. Chatbot_Instruction__c: whether Allowed_Positions__c and
     Is_Position_Restricted__c are visible, and the HTTP status of a count query
     that filters on the formula. Before the metadata deploy + FLS grant these
     read "absent" / 400 (expected); after, they must read "visible" / 200
     BEFORE the proxy code that selects them ships.
EXIT CODE: 1 if any field is absent or any call is not HTTP 200 (so before the
deploy + FLS grant it exits 1 on purpose), 0 only when everything is readable.

RUN from the cfo-bot-litellm repo root (it imports the proxy's own helper), with
the proxy's Salesforce env injected by Railway; filter the output as a belt:
  cd ~/Documents/GitHub/cfo-bot-litellm
  railway run --service LiteLLM -- ~/.venvs/cfo-litellm/bin/python \
    ~/Documents/GitHub/chatbot-instructions-apex/scripts/verify_proxy_reads.py \
    2>&1 | grep -vE "SF_|CLIENT|SECRET|TOKEN"
"""
import asyncio
import os
import sys
import urllib.parse

# The script lives outside the litellm repo; import from the current directory.
sys.path.insert(0, os.getcwd())
from callbacks.skills.salesforce import SF_API_VERSION, _authed_request  # noqa: E402

BASE = f"/services/data/{SF_API_VERSION}"
# Each failed check appends a short reason; any entry means exit code 1.
FAILURES = []


async def visible_fields(sobject, wanted):
    """Describe as the proxy user; a field missing from describe is unreadable to it."""
    response = await _authed_request("GET", f"{BASE}/sobjects/{sobject}/describe")
    if response.status_code != 200:
        print(f"{sobject} describe: HTTP {response.status_code}")
        FAILURES.append(f"{sobject} describe HTTP {response.status_code}")
        return
    fields = {f["name"]: f for f in response.json().get("fields", [])}
    for name in wanted:
        field = fields.get(name)
        state = "visible (readable)" if field else "absent (no field or no FLS)"
        detail = f", type={field.get('type')}" if field else ""
        print(f"  {sobject}.{name}: {state}{detail}")
        if not field:
            FAILURES.append(f"{sobject}.{name} absent")


async def count(soql):
    """Run a COUNT() query; print only the HTTP status and the number."""
    encoded = urllib.parse.urlencode({"q": soql})
    response = await _authed_request("GET", f"{BASE}/query/?{encoded}")
    if response.status_code == 200:
        print(f"  HTTP 200, count = {response.json().get('totalSize')}")
    else:
        # The error body names fields, not data; still keep it short.
        print(f"  HTTP {response.status_code}: {response.text[:160]}")
        FAILURES.append(f"query HTTP {response.status_code}")


async def main():
    print(f"API {SF_API_VERSION}, authenticated as the proxy's integration user")

    print("1. Contact (staff directory + login gate)")
    await visible_fields("Contact", ["Email", "Status__c", "Current_Position__c"])
    print("  SELECT COUNT() FROM Contact WHERE Status__c = 'Active Employee' AND Email != null")
    await count("SELECT COUNT() FROM Contact WHERE Status__c = 'Active Employee' AND Email != null")
    print("  ...AND Current_Position__c != null (the login gate needs a position)")
    await count(
        "SELECT COUNT() FROM Contact WHERE Status__c = 'Active Employee' "
        "AND Email != null AND Current_Position__c != null"
    )

    print("2. Chatbot_Instruction__c (position restriction fields)")
    await visible_fields("Chatbot_Instruction__c", ["Allowed_Positions__c", "Is_Position_Restricted__c"])
    print("  SELECT COUNT() FROM Chatbot_Instruction__c WHERE Is_Position_Restricted__c = true")
    await count("SELECT COUNT() FROM Chatbot_Instruction__c WHERE Is_Position_Restricted__c = true")

    # Skill versioning (grant_version_fls.py): the proxy's manifest query selects all
    # three of the first; an unreadable one would 400 the whole manifest.
    print("3. Chatbot_Instruction__c (skill versioning fields)")
    await visible_fields(
        "Chatbot_Instruction__c",
        ["Version_Number__c", "Version_Date__c", "Bundle_Fingerprint__c", "Created_From_Skill_ID__c"],
    )
    print("  SELECT COUNT() ... WHERE Active__c = true AND Version_Number__c != null (after the backfill = every active record)")
    await count("SELECT COUNT() FROM Chatbot_Instruction__c WHERE Active__c = true AND Version_Number__c != null")


    # Skill training link (2026-11-13): the library query selects ONLY Training_Link__c, a
    # CROSS-OBJECT formula over Vector_File__c, which this user has NO access to. Salesforce
    # hides the lookup Training_Resource__c from such a user (expected: it reads "absent"
    # and is never selected), but the formula still evaluates for it. This proves the
    # formula's values come through (counts only, never a value).
    print("4. Chatbot_Instruction__c (training link formula)")
    await visible_fields("Chatbot_Instruction__c", ["Training_Link__c"])
    soql = "SELECT Training_Link__c FROM Chatbot_Instruction__c WHERE Active__c = true AND Training_Link__c != null"
    response = await _authed_request("GET", f"{BASE}/query/?{urllib.parse.urlencode({'q': soql})}")
    if response.status_code != 200:
        print(f"  HTTP {response.status_code}: {response.text[:160]}")
        FAILURES.append(f"training query HTTP {response.status_code}")
        return
    rows = response.json().get("records", [])
    lms = [r for r in rows if "](https://tccfo-lms.web.app/training/" in (r.get("Training_Link__c") or "")]
    print(f"  HTTP 200, active records with a training link = {len(rows)}, learning portal links = {len(lms)}")
    expected = int(os.environ.get("EXPECT_TRAINING_LINKS", "0") or 0)
    if expected and len(rows) != expected:
        FAILURES.append(f"expected {expected} training links, read {len(rows)} (cross-object formula not visible?)")
    if len(lms) != len(rows):
        FAILURES.append("a Training_Link__c value is not a learning portal link")

if __name__ == "__main__":
    asyncio.run(main())
    if FAILURES:
        print(f"FAIL ({len(FAILURES)}): " + "; ".join(FAILURES))
        sys.exit(1)
    print("PASS: every field readable, every query HTTP 200")
