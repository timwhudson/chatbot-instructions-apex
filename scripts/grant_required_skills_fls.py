"""Grant field-level security (FLS) on Required_Skill_Names__c ("Required Skills").

Same procedure, safety checks and output as grant_version_fls.py, which this reuses
with a different field list: READ mirrors Reasoning_Effort__c's holders; EDIT goes to
nobody (Apex - ChatbotInstructionRequiredSkills - is the only writer, and Apex DML
isn't limited by FLS). Dry run by default; --apply inserts the missing rows, re-reads
and exits 1 on any mismatch or any Edit grant.

RUN (from this repo's root, AFTER manifest/required-skills-list.xml is deployed):
  python3 scripts/grant_required_skills_fls.py            # dry run
  python3 scripts/grant_required_skills_fls.py --apply    # real grant + verify
Rollback: sf data delete record -s FieldPermissions -i <Id> -o tccfo-prod
The reused messages mention "four fields" and proxy code: ignore those here, the
proxy never selects this field.
"""
import grant_version_fls as fls

# Field -> may System Administrator edit it? (False: nobody may.)
fls.NEW_FIELDS = {f"{fls.OBJ}.Required_Skill_Names__c": False}

if __name__ == "__main__":
    fls.main()
