/**
 * ChatbotInstructionRequiredSkills
 *
 * Keeps Chatbot_Instruction__c.Required_Skill_Names__c (label "Required Skills")
 * equal to the names of the skills on that record's Required Skills related list
 * (Required_Skill__c rows), A-Z, joined with ", ". It is read-only text for
 * people (page, list views, reports, the Salesforce connector); CFO Bot itself
 * reads the related list, never this field.
 *
 * WHY APEX AND NOT A FORMULA OR ROLL-UP SUMMARY:
 *   A formula can only read the record and the records it looks UP to; the
 *   Required Skill rows point DOWN at it. A roll-up summary only counts or adds
 *   numbers. So the text is rewritten whenever something it is built from changes:
 *     - a Required_Skill__c row is added, changed, deleted or undeleted
 *       (RequiredSkillTrigger -> handleRowChanges), and
 *     - a required skill is renamed (ChatbotInstructionTrigger after update ->
 *       handleAfterUpdate, which refreshes every skill that requires it).
 *   A new record starts blank (handleBeforeInsert), so a clone never carries the
 *   original's list. A skill restored from the Recycle Bin is refreshed
 *   (ChatbotInstructionTrigger after undelete): its rows come back without
 *   RequiredSkillTrigger running, and a required skill may have been renamed
 *   meanwhile. Nobody has Edit on the field, so only this class writes it.
 *
 * WHAT CAN'T GO STALE:
 *   - A required skill can't be deleted while a row points at it (the lookup is
 *     "don't allow deletion"), so a list never names a deleted skill.
 *   - Deleting a skill deletes its own rows; the skill is gone, nothing to update.
 *
 * VALIDATION RULES: every row change re-saves the parent skill, and a rename
 *   re-saves every requirer, so each of their validation rules runs. A NEW rule
 *   on Chatbot_Instruction__c must be gated with ISNEW()/ISCHANGED(...) (like
 *   Library_Listing_Rules), or an older record that breaks it can no longer have
 *   its Required Skills changed or its required skills renamed.
 *
 * VERSIONING: the parent update here changes only this field, which
 *   ChatbotInstructionVersioning never counts, so a skill's version number does
 *   not move when its Required Skills change.
 *
 * BULK SAFETY: 2 queries + 1 update per trigger chunk (plus 1 query for renames),
 *   however many records are saved together; unchanged lists are not saved.
 *
 * SHARING: without sharing, so the list names every required skill even when the
 *   person saving can't open some of them.
 */
public without sharing class ChatbotInstructionRequiredSkills {

    // Text(255): filterable in list views and reports. The longest list today is 84.
    private static final Integer MAX_LENGTH = 255;

    // ── BEFORE INSERT (Chatbot_Instruction__c): a new record has no rows yet ──
    public static void handleBeforeInsert(List<Chatbot_Instruction__c> newRecords) {
        for (Chatbot_Instruction__c rec : newRecords) {
            rec.Required_Skill_Names__c = null;
        }
    }

    // ── AFTER UPDATE (Chatbot_Instruction__c): a rename reaches every requirer ──
    public static void handleAfterUpdate(
        List<Chatbot_Instruction__c> newRecords,
        Map<Id, Chatbot_Instruction__c> oldMap
    ) {
        // Case-sensitive: a rename that only changes capitals must show too.
        Set<Id> renamed = new Set<Id>();
        for (Chatbot_Instruction__c rec : newRecords) {
            if (!ChatbotInstructionVersioning.sameString(rec.Name, oldMap.get(rec.Id).Name)) {
                renamed.add(rec.Id);
            }
        }
        // No rename in this save (the usual case): no query at all.
        if (renamed.isEmpty()) {
            return;
        }
        Set<Id> requirers = new Set<Id>();
        for (Required_Skill__c row : [
            SELECT Instruction__c FROM Required_Skill__c WHERE Required_Instruction__c IN :renamed
        ]) {
            requirers.add(row.Instruction__c);
        }
        refresh(requirers);
    }

    // ── AFTER insert / update / delete / undelete (Required_Skill__c) ──
    // newRows is null on delete, oldRows is null on insert/undelete. An update
    // refreshes both the old and the new parent (covers a re-pointed row).
    public static void handleRowChanges(List<Required_Skill__c> newRows, List<Required_Skill__c> oldRows) {
        Set<Id> parents = new Set<Id>();
        for (List<Required_Skill__c> rows : new List<List<Required_Skill__c>>{ newRows, oldRows }) {
            if (rows == null) {
                continue;
            }
            for (Required_Skill__c row : rows) {
                parents.add(row.Instruction__c);
            }
        }
        refresh(parents);
    }

    /**
     * Rewrites the list on each given skill and saves only the ones whose text
     * changed. Public so a one-off backfill can call it with every record's Id.
     */
    public static void refresh(Set<Id> instructionIds) {
        Set<Id> ids = new Set<Id>(instructionIds);
        ids.remove(null);
        if (ids.isEmpty()) {
            return;
        }

        // ── Step 1: the required skills' names per skill, already A-Z ──
        Map<Id, List<String>> namesBySkill = new Map<Id, List<String>>();
        for (Required_Skill__c row : [
            SELECT Instruction__c, Required_Instruction__r.Name
            FROM Required_Skill__c
            WHERE Instruction__c IN :ids
            ORDER BY Required_Instruction__r.Name
        ]) {
            if (!namesBySkill.containsKey(row.Instruction__c)) {
                namesBySkill.put(row.Instruction__c, new List<String>());
            }
            namesBySkill.get(row.Instruction__c).add(row.Required_Instruction__r.Name);
        }

        // ── Step 2: save only the lists that differ (case-sensitive) ──
        // A skill deleted in this transaction is simply not returned here.
        List<Chatbot_Instruction__c> changed = new List<Chatbot_Instruction__c>();
        for (Chatbot_Instruction__c rec : [
            SELECT Id, Required_Skill_Names__c FROM Chatbot_Instruction__c WHERE Id IN :ids
        ]) {
            String names = joinNames(namesBySkill.get(rec.Id));
            if (!ChatbotInstructionVersioning.sameString(names, rec.Required_Skill_Names__c)) {
                changed.add(new Chatbot_Instruction__c(Id = rec.Id, Required_Skill_Names__c = names));
            }
        }
        // All-or-nothing on purpose: if a skill can't be saved (one of its own
        // validation rules), the row change that triggered this fails with that
        // rule's message instead of leaving a wrong list behind.
        if (!changed.isEmpty()) {
            update changed;
        }
    }

    /** "A, B, C"; null for no rows; cut to the field's 255 characters with "...". */
    public static String joinNames(List<String> names) {
        if (names == null || names.isEmpty()) {
            return null;
        }
        return String.join(names, ', ').abbreviate(MAX_LENGTH);
    }
}
