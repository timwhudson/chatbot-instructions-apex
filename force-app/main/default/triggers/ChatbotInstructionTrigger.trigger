/**
 * Trigger: ChatbotInstructionTrigger
 * Object: Chatbot_Instruction__c
 *
 * Handles automatic sequencing of Index__c values across all
 * Chatbot_Instruction__c records. Ensures:
 *   - No duplicate Index__c values
 *   - No gaps in the sequence (always 1..N)
 *   - New records without an Index__c are appended at the end
 *   - Deleting a record closes the gap automatically
 *   - Inserting at an existing position shifts other records down
 *
 * Also (position-restricted skills): before update, refuses to restrict a
 * skill (fill Allowed_Positions__c) while another firm skill requires it.
 * See ChatbotInstructionRestrictionGuard.
 *
 * Also (skill versioning): before insert/update, stamps Version_Number__c and
 * Version_Date__c — 1 on insert, +1 only when the instruction text or the
 * bundle fingerprint really changes. See ChatbotInstructionVersioning.
 *
 * Also (Required Skills text field): a new record starts with a blank
 * Required_Skill_Names__c, after update a renamed skill's new name is written
 * into the list of every skill that requires it, and a skill restored from the
 * Recycle Bin gets its list rebuilt. Row changes are handled by
 * RequiredSkillTrigger. See ChatbotInstructionRequiredSkills.
 *
 * Delegates all logic to ChatbotInstructionIndexingService and
 * ChatbotInstructionRestrictionGuard to keep the trigger lean and testable.
 */
trigger ChatbotInstructionTrigger on Chatbot_Instruction__c (
    before insert, before update, after insert, after update, after delete, after undelete
) {
    // Recursion guard — prevents infinite loops when the service
    // updates sibling records during the rebuild process
    if (ChatbotInstructionIndexingService.isRunning) {
        return;
    }

    // ── BEFORE events: assign default/temp Index__c values ──────────
    if (Trigger.isBefore && Trigger.isInsert) {
        ChatbotInstructionIndexingService.handleBeforeInsert(Trigger.new);
        // Skill versioning: every new record starts at Version 1
        ChatbotInstructionVersioning.handleBeforeInsert(Trigger.new);
        // Required Skills text: no rows yet, so a clone never keeps the original's list
        ChatbotInstructionRequiredSkills.handleBeforeInsert(Trigger.new);
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        ChatbotInstructionIndexingService.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
        // Position-restricted skills: block restricting a skill that is still required
        ChatbotInstructionRestrictionGuard.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
        // Skill versioning: +1 only on a real text or bundle change
        ChatbotInstructionVersioning.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
    }

    // ── AFTER events: rebuild the full sequence ─────────────────────
    if (Trigger.isAfter && Trigger.isInsert) {
        ChatbotInstructionIndexingService.handleAfterInsert(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isUpdate) {
        ChatbotInstructionIndexingService.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        // Required Skills text: a rename reaches every skill that requires this one
        ChatbotInstructionRequiredSkills.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }

    if (Trigger.isAfter && Trigger.isDelete) {
        ChatbotInstructionIndexingService.handleAfterDelete(Trigger.old);
    }

    // Required Skills text: restored rows skip RequiredSkillTrigger, so rebuild the list
    if (Trigger.isAfter && Trigger.isUndelete) {
        ChatbotInstructionRequiredSkills.refresh(Trigger.newMap.keySet());
    }
}
