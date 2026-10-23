/**
 * ChatbotInstructionVersioningTest
 *
 * Proves ChatbotInstructionVersioning through the real trigger (and the real
 * Bundle_Fingerprint_Format validation rule), so a validate/deploy shows the
 * versioning behaves, not just that it compiles.
 *
 * Scenarios:
 *   1. Insert: Version 1 dated now, even when the insert carries a number/date
 *      (a clone, a Data Loader file).
 *   2. A real text change raises the number by one and moves the date.
 *   3. Changes that never count: line endings, trailing spaces, outer blank
 *      lines, Usage, Name, Active, Index (re-ordering), Library Description.
 *   4. Case matters: "Use" -> "use" is a real change (Apex `==` would miss it).
 *   5. Fingerprint: a new value raises the number; the same value re-pasted in
 *      capitals or with spaces does not (trimmed + lower-cased); clearing it is
 *      a change.
 *   6. A number sent by an API call is ignored (never goes down, never jumps).
 *   7. A blank old number is a first stamp (1), never an error.
 *   8. A malformed fingerprint is refused by the validation rule.
 *   9. Bulk: 200 records inserted and edited in one DML each (limits).
 *  10. normalize() unit cases, including a 131,072-character text.
 */
@isTest
private class ChatbotInstructionVersioningTest {

    private static final String FP_A = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    private static final String FP_B = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

    // A record that passes every other org rule (Usage + Instruction Text
    // required; inactive, so the library listing rule doesn't apply).
    private static Chatbot_Instruction__c makeRecord(String name, String text) {
        return new Chatbot_Instruction__c(
            Name = name,
            Usage__c = 'Test usage',
            Instruction_Text__c = text,
            Library_Description__c = 'Test description',
            Active__c = false
        );
    }

    private static Chatbot_Instruction__c reload(Id recordId) {
        return [
            SELECT Id, Version_Number__c, Version_Date__c, Bundle_Fingerprint__c, Instruction_Text__c
            FROM Chatbot_Instruction__c WHERE Id = :recordId
        ];
    }

    // Moves the stored Version_Date__c into the past (the trigger is bypassed
    // through the recursion guard), so a later "date moved" assert means
    // something within one test transaction.
    private static void backdate(Id recordId) {
        ChatbotInstructionIndexingService.isRunning = true;
        update new Chatbot_Instruction__c(Id = recordId, Version_Date__c = Datetime.now().addDays(-3));
        ChatbotInstructionIndexingService.isRunning = false;
    }

    @isTest
    static void insertStartsAtOneWhateverItCarries() {
        Chatbot_Instruction__c rec = makeRecord('Versioning insert', 'Body');
        rec.Version_Number__c = 42;
        rec.Version_Date__c = Datetime.newInstance(2000, 1, 1);
        insert rec;
        Chatbot_Instruction__c saved = reload(rec.Id);
        System.assertEquals(1, saved.Version_Number__c);
        System.assert(saved.Version_Date__c > Datetime.now().addMinutes(-5), 'dated now');
    }

    @isTest
    static void realTextChangeRaisesTheNumber() {
        Chatbot_Instruction__c rec = makeRecord('Versioning text', 'Line one\nLine two');
        insert rec;
        backdate(rec.Id);
        update new Chatbot_Instruction__c(Id = rec.Id, Instruction_Text__c = 'Line one\nLine 2');
        Chatbot_Instruction__c saved = reload(rec.Id);
        System.assertEquals(2, saved.Version_Number__c);
        System.assert(saved.Version_Date__c > Datetime.now().addMinutes(-5), 'date moved to now');
    }

    @isTest
    static void cosmeticAndNonContentEditsNeverCount() {
        Chatbot_Instruction__c rec = makeRecord('Versioning cosmetic', 'Line one\nLine two');
        insert rec;
        backdate(rec.Id);
        Datetime before = reload(rec.Id).Version_Date__c;
        update new Chatbot_Instruction__c(Id = rec.Id, Instruction_Text__c = '\r\nLine one   \r\nLine two\t\n\n');
        update new Chatbot_Instruction__c(Id = rec.Id, Usage__c = 'Other usage', Name = 'Renamed',
            Library_Description__c = 'Other description', Index__c = 1);
        Chatbot_Instruction__c saved = reload(rec.Id);
        System.assertEquals(1, saved.Version_Number__c);
        System.assertEquals(before, saved.Version_Date__c, 'date unchanged');
    }

    @isTest
    static void caseChangeIsARealChange() {
        Chatbot_Instruction__c rec = makeRecord('Versioning case', 'Use the template');
        insert rec;
        update new Chatbot_Instruction__c(Id = rec.Id, Instruction_Text__c = 'use the template');
        System.assertEquals(2, reload(rec.Id).Version_Number__c);
    }

    @isTest
    static void fingerprintChanges() {
        Chatbot_Instruction__c rec = makeRecord('Versioning bundle', 'Pointer line');
        rec.Bundle_Fingerprint__c = '  ' + FP_A.toUpperCase() + ' ';
        insert rec;
        System.assertEquals(FP_A, reload(rec.Id).Bundle_Fingerprint__c, 'trimmed + lower-cased on insert');

        update new Chatbot_Instruction__c(Id = rec.Id, Bundle_Fingerprint__c = FP_A.toUpperCase());
        System.assertEquals(1, reload(rec.Id).Version_Number__c, 're-paste in capitals is not a change');

        update new Chatbot_Instruction__c(Id = rec.Id, Bundle_Fingerprint__c = FP_B);
        System.assertEquals(2, reload(rec.Id).Version_Number__c, 'a new bundle is a new version');

        update new Chatbot_Instruction__c(Id = rec.Id, Bundle_Fingerprint__c = null);
        System.assertEquals(3, reload(rec.Id).Version_Number__c, 'clearing the fingerprint is a change');
    }

    @isTest
    static void numberSentByAnApiCallIsIgnored() {
        Chatbot_Instruction__c rec = makeRecord('Versioning api', 'Body');
        insert rec;
        update new Chatbot_Instruction__c(Id = rec.Id, Version_Number__c = 0, Version_Date__c = Datetime.newInstance(2000, 1, 1));
        Chatbot_Instruction__c saved = reload(rec.Id);
        System.assertEquals(1, saved.Version_Number__c, 'never goes down');
        System.assert(saved.Version_Date__c > Datetime.now().addMinutes(-5), 'date kept');

        update new Chatbot_Instruction__c(Id = rec.Id, Version_Number__c = 99, Instruction_Text__c = 'Body 2');
        System.assertEquals(2, reload(rec.Id).Version_Number__c, 'a real change is +1, never a jump');
    }

    @isTest
    static void blankOldNumberIsAFirstStamp() {
        Chatbot_Instruction__c rec = makeRecord('Versioning blank', 'Body');
        insert rec;
        ChatbotInstructionIndexingService.isRunning = true;
        update new Chatbot_Instruction__c(Id = rec.Id, Version_Number__c = null, Version_Date__c = null);
        ChatbotInstructionIndexingService.isRunning = false;
        update new Chatbot_Instruction__c(Id = rec.Id, Usage__c = 'Touch');
        Chatbot_Instruction__c saved = reload(rec.Id);
        System.assertEquals(1, saved.Version_Number__c);
        System.assertNotEquals(null, saved.Version_Date__c);
    }

    @isTest
    static void malformedFingerprintIsRefused() {
        Chatbot_Instruction__c rec = makeRecord('Versioning bad fp', 'Body');
        rec.Bundle_Fingerprint__c = FP_A.substring(0, 60);
        Database.SaveResult result = Database.insert(rec, false);
        System.assert(!result.isSuccess(), 'a truncated fingerprint is refused');
        System.assertEquals(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, result.getErrors()[0].getStatusCode());

        Chatbot_Instruction__c other = makeRecord('Versioning bad skill id', 'Body');
        other.Created_From_Skill_ID__c = 'NOT-A-SKILL-ID';
        System.assert(!Database.insert(other, false).isSuccess(), 'a malformed skill ID is refused');
    }

    @isTest
    static void bulkInsertAndEdit() {
        List<Chatbot_Instruction__c> recs = new List<Chatbot_Instruction__c>();
        for (Integer i = 0; i < 200; i++) {
            recs.add(makeRecord('Versioning bulk ' + i, 'Body ' + i));
        }
        insert recs;
        for (Integer i = 0; i < 200; i++) {
            recs[i].Instruction_Text__c = Math.mod(i, 2) == 0 ? 'Body ' + i + ' changed' : 'Body ' + i + '  ';
        }
        update recs;
        Integer raised = 0;
        for (Chatbot_Instruction__c saved : [
            SELECT Version_Number__c FROM Chatbot_Instruction__c WHERE Name LIKE 'Versioning bulk %'
        ]) {
            if (saved.Version_Number__c == 2) {
                raised++;
            } else {
                System.assertEquals(1, saved.Version_Number__c);
            }
        }
        System.assertEquals(100, raised, 'only the real changes rose');
    }

    @isTest
    static void normalizeUnitCases() {
        System.assertEquals('', ChatbotInstructionVersioning.normalize(null));
        System.assertEquals('a\n\nb', ChatbotInstructionVersioning.normalize('\n \ta  \r\n\r\nb\t \n\n'));
        System.assertEquals('a\nb', ChatbotInstructionVersioning.normalize('a\rb'));
        System.assertEquals('a  b', ChatbotInstructionVersioning.normalize('a  b'), 'inner spaces count');
        System.assert(ChatbotInstructionVersioning.textChanged('A', 'a'), 'case is a change');
        System.assert(!ChatbotInstructionVersioning.textChanged(null, ''), 'null and empty are the same');
        System.assert(ChatbotInstructionVersioning.sameString(null, null));
        System.assert(!ChatbotInstructionVersioning.sameString('x', null));
        System.assertEquals(null, ChatbotInstructionVersioning.cleanFingerprint('   '));

        // A full-size instruction text (131,072 characters, many lines) normalizes
        // without hitting a governor limit.
        String line = 'x'.repeat(60) + '   \r\n';
        String big = line.repeat(131072 / line.length());
        Long started = Limits.getCpuTime();
        String cleaned = ChatbotInstructionVersioning.normalize(big);
        System.assert(cleaned.length() > 100000);
        System.assert(!cleaned.contains('\r') && !cleaned.contains(' \n'));
        System.assert(Limits.getCpuTime() - started < 9000, 'within the CPU limit');
    }
}
