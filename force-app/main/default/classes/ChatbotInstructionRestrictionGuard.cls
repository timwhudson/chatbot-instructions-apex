/**
 * ChatbotInstructionRestrictionGuard
 *
 * Position-restricted skills: refuses to restrict a skill (fill
 * Allowed_Positions__c, label "Restricted to Positions") while another firm
 * skill still lists it as a required skill.
 *
 * WHY THIS IS APEX AND NOT A VALIDATION RULE:
 *   "Is anyone requiring this skill?" is answered by OTHER records:
 *     1. Required_Skill__c junction rows whose Required_Instruction__c points
 *        here. That side is a lookup (not master-detail), so no roll-up
 *        summary can count them.
 *     2. The legacy single link Chatbot_Instruction__c.Instruction_Dependency__c
 *        on other skills pointing here.
 *   A validation rule can only see the record being saved and its parents, not
 *   the records that point at it, so the check has to query.
 *
 *   The OTHER direction (adding a requirement on a skill that is already
 *   restricted) is covered by validation rules, not here:
 *     - Required_Skill__c.Cannot_Require_Restricted_Skill
 *     - Chatbot_Instruction__c.Cannot_Depend_On_Restricted_Skill
 *
 * WHEN IT DOES WORK:
 *   Only for records whose Allowed_Positions__c goes from blank to filled in
 *   this save. Every other save (an unrelated edit, re-ordering, changing the
 *   positions on an already-restricted skill) returns before any query.
 *
 * BULK SAFETY:
 *   At most one SOQL query per store (2 in total) per trigger chunk, however
 *   many records are saved together.
 *
 * SHARING:
 *   "without sharing" so the check sees every requiring skill, even one the
 *   editing user could not open. A partial view would let a restriction slip
 *   through.
 *
 * RECYCLE BIN (ALL ROWS):
 *   Both queries include deleted rows still in the Recycle Bin. Undelete does
 *   not re-run validation rules, so without this an editor could delete the
 *   requiring skill / its Required_Skill__c row / a legacy linker, restrict
 *   this skill, then undelete and bring back a requirement on a restricted
 *   skill. Known limit: rows emptied from the bin keep blocking until
 *   Salesforce physically purges them, because ALL ROWS still returns them and
 *   no field tells them apart from rows that can be undeleted. That fails
 *   closed (a restriction waits; nothing leaks).
 */
public without sharing class ChatbotInstructionRestrictionGuard {

    // ── BEFORE UPDATE ────────────────────────────────────────────────
    public static void handleBeforeUpdate(
        List<Chatbot_Instruction__c> newRecords,
        Map<Id, Chatbot_Instruction__c> oldMap
    ) {
        // ── Step 1: which records are becoming restricted in this save? ──
        Set<Id> newlyRestricted = new Set<Id>();
        for (Chatbot_Instruction__c rec : newRecords) {
            Boolean wasOpen = String.isBlank(oldMap.get(rec.Id).Allowed_Positions__c);
            if (wasOpen && String.isNotBlank(rec.Allowed_Positions__c)) {
                newlyRestricted.add(rec.Id);
            }
        }
        // Nothing is being restricted: no queries at all.
        if (newlyRestricted.isEmpty()) {
            return;
        }

        // ── Step 2: find a requiring skill for each newly-restricted one ──
        // Key = the skill being restricted; value = the name of ONE skill that
        // requires it (the error message names it so the editor knows where
        // to go). Sorted by name so the message is stable.
        Map<Id, String> requiredBy = new Map<Id, String>();

        // Store 1: Required_Skill__c junction rows (query #1), Recycle Bin included.
        for (Required_Skill__c row : [
            SELECT Required_Instruction__c, Instruction__r.Name
            FROM Required_Skill__c
            WHERE Required_Instruction__c IN :newlyRestricted
            ORDER BY Instruction__r.Name
            ALL ROWS
        ]) {
            noteFirst(requiredBy, row.Required_Instruction__c, row.Instruction__r.Name);
        }

        // Store 2a: legacy lookup on records in THIS save. Use their new,
        // in-flight value: the database still holds the old one, so a record
        // that adds or keeps a link to a skill restricted in the same save
        // would otherwise be missed.
        for (Chatbot_Instruction__c rec : newRecords) {
            if (newlyRestricted.contains(rec.Instruction_Dependency__c)) {
                noteFirst(requiredBy, rec.Instruction_Dependency__c, rec.Name);
            }
        }

        // Store 2b: legacy lookup on every OTHER record (query #2), Recycle Bin
        // included. Records in this save are excluded because 2a already judged
        // them by their new value.
        Set<Id> inThisSave = oldMap.keySet();
        for (Chatbot_Instruction__c rec : [
            SELECT Name, Instruction_Dependency__c
            FROM Chatbot_Instruction__c
            WHERE Instruction_Dependency__c IN :newlyRestricted
              AND Id NOT IN :inThisSave
            ORDER BY Name
            ALL ROWS
        ]) {
            noteFirst(requiredBy, rec.Instruction_Dependency__c, rec.Name);
        }

        // ── Step 3: refuse the save on each record that is still required ──
        // addError blocks only that record; others in the same save proceed
        // when the caller allows partial success.
        for (Chatbot_Instruction__c rec : newRecords) {
            String requirer = requiredBy.get(rec.Id);
            if (requirer != null) {
                rec.addError(
                    'Can\'t restrict this skill: "' + requirer +
                    '" (possibly in the Recycle Bin) lists it as a required skill. ' +
                    'Remove that requirement first.'
                );
            }
        }
    }

    // ── HELPER: keep the first requiring name found for a skill ─────
    private static void noteFirst(Map<Id, String> requiredBy, Id skillId, String requirerName) {
        if (!requiredBy.containsKey(skillId)) {
            requiredBy.put(skillId, requirerName);
        }
    }
}
