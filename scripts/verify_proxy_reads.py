"""Read-only check, run AS THE LITELLM PROXY'S SALESFORCE USER, of the fields the
position-restriction feature reads.

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


async def visible_fields(sobject, wanted):
    """Describe as the proxy user; a field missing from describe is unreadable to it."""
    response = await _authed_request("GET", f"{BASE}/sobjects/{sobject}/describe")
    if response.status_code != 200:
        print(f"{sobject} describe: HTTP {response.status_code}")
        return
    fields = {f["name"]: f for f in response.json().get("fields", [])}
    for name in wanted:
        field = fields.get(name)
        state = "visible (readable)" if field else "absent (no field or no FLS)"
        detail = f", type={field.get('type')}" if field else ""
        print(f"  {sobject}.{name}: {state}{detail}")


async def count(soql):
    """Run a COUNT() query; print only the HTTP status and the number."""
    encoded = urllib.parse.urlencode({"q": soql})
    response = await _authed_request("GET", f"{BASE}/query/?{encoded}")
    if response.status_code == 200:
        print(f"  HTTP 200, count = {response.json().get('totalSize')}")
    else:
        # The error body names fields, not data; still keep it short.
        print(f"  HTTP {response.status_code}: {response.text[:160]}")


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


if __name__ == "__main__":
    asyncio.run(main())
