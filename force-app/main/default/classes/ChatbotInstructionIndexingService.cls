/**
 * ChatbotInstructionIndexingService
 *
 * Core logic for maintaining a gapless, duplicate-free sequence of
 * Index__c values across all Chatbot_Instruction__c records.
 *
 * DATA MODEL ASSUMPTIONS:
 *   - Chatbot_Instruction__c has field:
 *       Index__c  (Number, optional on create, whole numbers only)
 *   - This is a flat list — no parent-child hierarchy.
 *   - Every record gets a unique integer index, 1..N, with no gaps.
 *
 * SEQUENCE RULES:
 *   1. Global sequence: Every record gets a unique integer, 1..N, no gaps.
 *   2. When a user supplies a duplicate index, existing records shift down
 *      (increment by 1) to make room for the new record at that position.
 *   3. When no index is supplied (null), the record is placed at the end
 *      of the sequence.
 *   4. Deletions compact the sequence automatically — remaining records
 *      are renumbered to close the gap.
 *   5. Updates that change Index__c trigger a full rebuild to maintain
 *      the gapless sequence.
 *
 * APPROACH:
 *   We use the same proven "rebuild" strategy as TrainingSectionNumberingService:
 *     1. In BEFORE triggers, we validate/default the incoming Index__c.
 *     2. In AFTER triggers, we call rebuildAllIndexes() which:
 *        a. Loads ALL Chatbot_Instruction__c records.
 *        b. Sorts them by current Index__c (with tiebreaker on Id).
 *        c. Assigns a clean 1..N sequence.
 *        d. Updates only records whose index actually changed.
 *   This is simple, correct, and safe for the expected volume (not millions
 *   of records). It guarantees rules 1-5 are always satisfied after every
 *   DML operation.
 */
public class ChatbotInstructionIndexingService {

    // ── Recursion guard ──────────────────────────────────────────────
    // Prevents infinite loops when rebuildAllIndexes() updates records,
    // which would otherwise re-fire the trigger.
    public static Boolean isRunning = false;

    // ── BEFORE INSERT ────────────────────────────────────────────────
    // Assign a temporary Index__c to records that don't have one so the
    // record can be saved without a null value. The real index will be
    // assigned in the AFTER trigger rebuild.
    public static void handleBeforeInsert(List<Chatbot_Instruction__c> newRecords) {
        // Get the current max so temp values won't collide during insert DML
        Decimal currentMax = getCurrentMaxIndex();

        for (Chatbot_Instruction__c rec : newRecords) {
            if (rec.Index__c == null) {
                // Assign next available number — AFTER trigger will finalize
                currentMax++;
                rec.Index__c = currentMax;
            }
        }
    }

    // ── BEFORE UPDATE ────────────────────────────────────────────────
    // If the user blanks out Index__c on an update, assign the current
    // max + 1 so the record lands at the end of the sequence. Otherwise,
    // let the user's value through — the AFTER trigger will handle
    // resolving any conflicts.
    public static void handleBeforeUpdate(
        List<Chatbot_Instruction__c> newRecords,
        Map<Id, Chatbot_Instruction__c> oldMap
    ) {
        Decimal currentMax = null; // Lazy-load only if needed

        for (Chatbot_Instruction__c rec : newRecords) {
            if (rec.Index__c == null) {
                // Lazy-load max only once if we encounter a null Index__c
                if (currentMax == null) {
                    currentMax = getCurrentMaxIndex();
                }
                currentMax++;
                rec.Index__c = currentMax;
            }
        }
    }

    // ── AFTER INSERT ─────────────────────────────────────────────────
    // Always rebuild after inserting new records — this handles both
    // "append at end" and "insert at specific position" scenarios.
    public static void handleAfterInsert(List<Chatbot_Instruction__c> newRecords) {
        rebuildAllIndexes();
    }

    // ── AFTER UPDATE ─────────────────────────────────────────────────
    // Only rebuild if Index__c actually changed on at least one record.
    // This avoids unnecessary rebuilds when unrelated fields are updated.
    public static void handleAfterUpdate(
        List<Chatbot_Instruction__c> newRecords,
        Map<Id, Chatbot_Instruction__c> oldMap
    ) {
        Boolean needsRebuild = false;
        for (Chatbot_Instruction__c rec : newRecords) {
            Chatbot_Instruction__c old = oldMap.get(rec.Id);
            if (rec.Index__c != old.Index__c) {
                needsRebuild = true;
                break;
            }
        }
        if (needsRebuild) {
            rebuildAllIndexes();
        }
    }

    // ── AFTER DELETE ─────────────────────────────────────────────────
    // Always rebuild after deletion to close any gaps in the sequence.
    public static void handleAfterDelete(List<Chatbot_Instruction__c> oldRecords) {
        rebuildAllIndexes();
    }

    // ══════════════════════════════════════════════════════════════════
    //  CORE REBUILD LOGIC
    // ══════════════════════════════════════════════════════════════════

    /**
     * Loads all Chatbot_Instruction__c records and assigns a clean 1..N
     * sequence based on their current Index__c values.
     *
     * Ordering strategy:
     *   1. Sort all records by Index__c ascending (nulls last).
     *   2. Tiebreaker: When two records share the same Index__c (duplicate),
     *      the more recently created record (higher Id) comes first. This
     *      implements "new record takes the position, existing records
     *      shift down" behavior.
     *   3. Walk through the sorted list and assign 1, 2, 3, ... N.
     *   4. Only update records whose index actually changed (optimization).
     */
    public static void rebuildAllIndexes() {
        // Load all records, sorted by Index__c ascending.
        // Secondary sort by Id DESC ensures newer records win the position
        // when duplicates exist (higher Salesforce Id = created more recently).
        List<Chatbot_Instruction__c> allRecords = [
            SELECT Id, Index__c
            FROM Chatbot_Instruction__c
            ORDER BY Index__c ASC NULLS LAST, Id DESC
        ];

        // Nothing to do if the object has no records
        if (allRecords.isEmpty()) return;

        // ── Assign sequential indexes ──────────────────────────────────
        // Walk through the sorted list and assign 1..N.
        // Only add to the update list if the index actually changed.
        Decimal seq = 1;
        List<Chatbot_Instruction__c> toUpdate = new List<Chatbot_Instruction__c>();

        for (Chatbot_Instruction__c rec : allRecords) {
            if (rec.Index__c != seq) {
                toUpdate.add(new Chatbot_Instruction__c(
                    Id = rec.Id,
                    Index__c = seq
                ));
            }
            seq++;
        }

        // ── Update changed records (with recursion guard) ──────────────
        // Set the guard before updating so the trigger knows to skip
        // when it fires again from our update DML.
        if (!toUpdate.isEmpty()) {
            isRunning = true;
            try {
                update toUpdate;
            } finally {
                // Always clear the guard, even if the update fails,
                // so we don't permanently disable the trigger.
                isRunning = false;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  HELPER: Get current max Index__c
    // ══════════════════════════════════════════════════════════════════

    /**
     * Returns the highest Index__c value currently in the database.
     * Returns 0 if no Chatbot_Instruction__c records exist.
     * Used by BEFORE triggers to assign temporary index values.
     */
    private static Decimal getCurrentMaxIndex() {
        List<AggregateResult> results = [
            SELECT MAX(Index__c) maxIdx
            FROM Chatbot_Instruction__c
        ];
        Decimal maxIdx = (Decimal) results[0].get('maxIdx');
        return maxIdx != null ? maxIdx : 0;
    }
}
