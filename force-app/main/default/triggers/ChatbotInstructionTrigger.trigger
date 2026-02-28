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
 * Delegates all logic to ChatbotInstructionIndexingService to keep
 * the trigger lean and testable.
 */
trigger ChatbotInstructionTrigger on Chatbot_Instruction__c (
    before insert, before update, after insert, after update, after delete
) {
    // Recursion guard — prevents infinite loops when the service
    // updates sibling records during the rebuild process
    if (ChatbotInstructionIndexingService.isRunning) {
        return;
    }

    // ── BEFORE events: assign default/temp Index__c values ──────────
    if (Trigger.isBefore && Trigger.isInsert) {
        ChatbotInstructionIndexingService.handleBeforeInsert(Trigger.new);
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        ChatbotInstructionIndexingService.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
    }

    // ── AFTER events: rebuild the full sequence ─────────────────────
    if (Trigger.isAfter && Trigger.isInsert) {
        ChatbotInstructionIndexingService.handleAfterInsert(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isUpdate) {
        ChatbotInstructionIndexingService.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }

    if (Trigger.isAfter && Trigger.isDelete) {
        ChatbotInstructionIndexingService.handleAfterDelete(Trigger.old);
    }
}
