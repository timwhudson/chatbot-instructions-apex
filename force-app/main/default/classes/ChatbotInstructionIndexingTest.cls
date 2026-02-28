/**
 * ChatbotInstructionIndexingTest
 *
 * Test class for ChatbotInstructionTrigger and ChatbotInstructionIndexingService.
 * Covers all core sequencing scenarios:
 *   1. Insert with no index → appended at end
 *   2. Insert with duplicate index → new record takes position, others shift
 *   3. Delete → gap is closed automatically
 *   4. Update index to a new position → records reorder correctly
 *   5. Update index to null → record moves to end of sequence
 *   6. Bulk insert and delete → no gaps across all records
 *   7. Insert at position beyond current max → clamped to end of sequence
 */
@isTest
public class ChatbotInstructionIndexingTest {

    // ── Helper: create an instruction with optional index ──────────
    private static Chatbot_Instruction__c makeInstruction(String name, Decimal idx) {
        return new Chatbot_Instruction__c(
            Name = name,
            Index__c = idx
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 1: Insert with no index → gets appended at end
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testInsertWithoutIndex() {
        // Insert 3 records with explicit indexes
        Chatbot_Instruction__c i1 = makeInstruction('Instruction A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('Instruction B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('Instruction C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Insert a 4th with no index — should be assigned 4
        Chatbot_Instruction__c i4 = makeInstruction('Instruction D', null);
        insert i4;

        // Verify the new record got appended at position 4
        i4 = [SELECT Index__c FROM Chatbot_Instruction__c WHERE Id = :i4.Id];
        System.assertEquals(4, i4.Index__c, 'Record with no index should be assigned 4 (end of sequence)');
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 2: Duplicate index → new record takes position, others shift
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testInsertDuplicateIndex() {
        // Insert 3 records at positions 1, 2, 3
        Chatbot_Instruction__c i1 = makeInstruction('Instruction A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('Instruction B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('Instruction C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Insert a new record also claiming index 2
        Chatbot_Instruction__c i4 = makeInstruction('Instruction D', 2);
        insert i4;

        // Reload all records
        Map<Id, Chatbot_Instruction__c> reloaded = new Map<Id, Chatbot_Instruction__c>(
            [SELECT Id, Index__c FROM Chatbot_Instruction__c ORDER BY Index__c]
        );

        // i1 stays at 1, i4 gets 2 (new record wins), i2 shifts to 3, i3 shifts to 4
        System.assertEquals(1, reloaded.get(i1.Id).Index__c, 'Instruction A should stay at 1');
        System.assertEquals(2, reloaded.get(i4.Id).Index__c, 'Instruction D (new) should take position 2');
        System.assertEquals(3, reloaded.get(i2.Id).Index__c, 'Instruction B should shift to 3');
        System.assertEquals(4, reloaded.get(i3.Id).Index__c, 'Instruction C should shift to 4');
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 3: Delete → gap is filled
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testDeleteFillsGap() {
        // Insert 3 records
        Chatbot_Instruction__c i1 = makeInstruction('A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Delete the middle record
        delete i2;

        // Remaining records should be renumbered 1, 2 with no gap
        List<Chatbot_Instruction__c> remaining = [
            SELECT Id, Index__c FROM Chatbot_Instruction__c ORDER BY Index__c
        ];

        System.assertEquals(2, remaining.size(), 'Should have 2 records remaining');
        System.assertEquals(1, remaining[0].Index__c, 'First remaining record should be at index 1');
        System.assertEquals(2, remaining[1].Index__c, 'Second remaining record should be at index 2');
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 4: Update index to move a record to a different position
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testUpdateIndexReorders() {
        // Insert 4 records in order
        Chatbot_Instruction__c i1 = makeInstruction('A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('C', 3);
        Chatbot_Instruction__c i4 = makeInstruction('D', 4);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3, i4 };

        // Move record D from position 4 to position 2
        i4.Index__c = 2;
        update i4;

        // Reload all records
        Map<Id, Chatbot_Instruction__c> reloaded = new Map<Id, Chatbot_Instruction__c>(
            [SELECT Id, Index__c FROM Chatbot_Instruction__c ORDER BY Index__c]
        );

        // A stays at 1, D takes 2, B shifts to 3, C shifts to 4
        System.assertEquals(1, reloaded.get(i1.Id).Index__c, 'A should stay at 1');
        System.assertEquals(2, reloaded.get(i4.Id).Index__c, 'D should move to 2');
        System.assertEquals(3, reloaded.get(i2.Id).Index__c, 'B should shift to 3');
        System.assertEquals(4, reloaded.get(i3.Id).Index__c, 'C should shift to 4');
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 5: Update index to null → record moves to end
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testUpdateIndexToNull() {
        // Insert 3 records
        Chatbot_Instruction__c i1 = makeInstruction('A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Clear the index on record A (position 1) — should move to end
        i1.Index__c = null;
        update i1;

        // Reload all records
        Map<Id, Chatbot_Instruction__c> reloaded = new Map<Id, Chatbot_Instruction__c>(
            [SELECT Id, Index__c FROM Chatbot_Instruction__c ORDER BY Index__c]
        );

        // B should be 1, C should be 2, A should be 3 (end)
        System.assertEquals(1, reloaded.get(i2.Id).Index__c, 'B should move to 1');
        System.assertEquals(2, reloaded.get(i3.Id).Index__c, 'C should move to 2');
        System.assertEquals(3, reloaded.get(i1.Id).Index__c, 'A should move to 3 (end)');
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 6: Bulk insert and delete → no gaps across all records
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testNoGapsAfterBulkOperations() {
        // Insert 20 records
        List<Chatbot_Instruction__c> records = new List<Chatbot_Instruction__c>();
        for (Integer i = 1; i <= 20; i++) {
            records.add(makeInstruction('Instruction ' + i, i));
        }
        insert records;

        // Delete records at positions 5, 10, 15 (three scattered deletions)
        delete new List<Chatbot_Instruction__c>{
            records[4], records[9], records[14]
        };

        // Verify remaining 17 records are numbered 1..17 with no gaps
        List<Chatbot_Instruction__c> remaining = [
            SELECT Index__c FROM Chatbot_Instruction__c ORDER BY Index__c
        ];

        System.assertEquals(17, remaining.size(), 'Should have 17 records after deleting 3');
        for (Integer i = 0; i < remaining.size(); i++) {
            System.assertEquals(i + 1, remaining[i].Index__c,
                'Position ' + (i + 1) + ' should exist with no gaps');
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 7: Insert at position beyond current max → clamped to end
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testInsertBeyondMax() {
        // Insert 3 records
        Chatbot_Instruction__c i1 = makeInstruction('A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Insert a record claiming index 100 (way beyond max of 3)
        Chatbot_Instruction__c i4 = makeInstruction('D', 100);
        insert i4;

        // The rebuild should place it at position 4 (end), not 100
        List<Chatbot_Instruction__c> all = [
            SELECT Id, Index__c FROM Chatbot_Instruction__c ORDER BY Index__c
        ];

        System.assertEquals(4, all.size(), 'Should have 4 records');
        // Verify gapless sequence 1..4
        for (Integer i = 0; i < all.size(); i++) {
            System.assertEquals(i + 1, all[i].Index__c,
                'Position ' + (i + 1) + ' should exist — no gaps allowed');
        }
        // D should be at the end (position 4) since 100 > max
        Chatbot_Instruction__c reloadedD = [SELECT Index__c FROM Chatbot_Instruction__c WHERE Id = :i4.Id];
        System.assertEquals(4, reloadedD.Index__c, 'Record with index 100 should be clamped to 4');
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 8: Multiple records inserted with no index → all get
    //          sequential indexes at end
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testBulkInsertWithoutIndexes() {
        // Insert 3 records with explicit indexes
        Chatbot_Instruction__c i1 = makeInstruction('A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Insert 3 more with no indexes — should all end up at 4, 5, 6
        Chatbot_Instruction__c i4 = makeInstruction('D', null);
        Chatbot_Instruction__c i5 = makeInstruction('E', null);
        Chatbot_Instruction__c i6 = makeInstruction('F', null);
        insert new List<Chatbot_Instruction__c>{ i4, i5, i6 };

        // Verify all 6 records have gapless sequence 1..6
        List<Chatbot_Instruction__c> all = [
            SELECT Index__c FROM Chatbot_Instruction__c ORDER BY Index__c
        ];

        System.assertEquals(6, all.size(), 'Should have 6 records');
        for (Integer i = 0; i < all.size(); i++) {
            System.assertEquals(i + 1, all[i].Index__c,
                'Position ' + (i + 1) + ' should exist in gapless sequence');
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  TEST 9: Delete all records → no errors on empty table
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void testDeleteAllRecords() {
        // Insert 3 records
        Chatbot_Instruction__c i1 = makeInstruction('A', 1);
        Chatbot_Instruction__c i2 = makeInstruction('B', 2);
        Chatbot_Instruction__c i3 = makeInstruction('C', 3);
        insert new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Delete all of them — should not throw any errors
        delete new List<Chatbot_Instruction__c>{ i1, i2, i3 };

        // Verify table is empty
        List<Chatbot_Instruction__c> remaining = [
            SELECT Index__c FROM Chatbot_Instruction__c
        ];
        System.assertEquals(0, remaining.size(), 'All records should be deleted');
    }
}
