/**
 * ChatbotInstructionLibraryRuleTest
 *
 * Proves the Library_Listing_Rules validation rule against the real org rule, so
 * a validate/deploy shows it behaves (not just that it compiles).
 *
 * The rule (skill library, PLAN decisions 72 + 76, 2026-10-20): the CFO Bot skill
 * library lists every ACTIVE record that is neither Always Include nor Proxy
 * Injected, so such a record can't be saved without a Library_Description__c.
 * A whitespace-only description counts as blank (TRIM). The rule is checked only
 * when the record is new or one of its four inputs changes (Active, Always
 * Include, Proxy Injected, Library Description), so the re-index trigger's
 * sibling updates (Index__c only) never trip it.
 *
 * Assertions check WHERE the error sits (Library_Description__c) and that it is a
 * validation-rule error, not the message wording, so editing the message in Setup
 * doesn't break these tests.
 *
 * Scenarios:
 *   1. Insert matrix (one bulk save, partial success): active + blank and active +
 *      whitespace are refused; Always Include, Proxy Injected and inactive records
 *      with a blank description save; an active described record saves.
 *   2. Clearing the description of a listed skill is refused.
 *   3. Every change that would make a blank record listed is refused: activating
 *      it, unticking Always Include, unticking Proxy Injected.
 *   4. A full re-index (insert at position 1 shifts every sibling) saves while the
 *      siblings include blank-description exempt records, and an unrelated edit of
 *      a listed skill saves.
 *      Known limit: an ACTIVE listed record with a blank description can't be built
 *      in a test, because every path to one (insert, activate, untick either box,
 *      clear the description) is a guarded change the rule refuses. Such records
 *      could only predate the rule (0 at launch); the change guard is what keeps a
 *      reorder from tripping over one.
 */
@isTest
private class ChatbotInstructionLibraryRuleTest {

    // ── Helper: a record that passes every OTHER org rule (Usage_Required,
    //    Instruction_Text_Required); the caller sets the library-relevant fields ──
    private static Chatbot_Instruction__c makeRecord(String name, String description) {
        return new Chatbot_Instruction__c(
            Name = name,
            Usage__c = 'Test usage',
            Instruction_Text__c = 'Test instruction text',
            Library_Description__c = description
        );
    }

    // ── Helper: assert a save was refused by a validation rule on the description ──
    private static void assertRefusedByRule(Database.SaveResult result, String label) {
        System.assert(!result.isSuccess(), label + ' should be refused');
        Database.Error error = result.getErrors()[0];
        System.assertEquals(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, error.getStatusCode(),
            label + ': expected a validation-rule error, got ' + error.getStatusCode() + ': ' + error.getMessage());
        System.assertEquals(new List<String>{ 'Library_Description__c' }, error.getFields(),
            label + ': error should sit on Library Description: ' + error.getMessage());
    }

    @isTest
    static void ruleRefusesOnlyListedSkillsWithoutDescription() {
        Chatbot_Instruction__c blank = makeRecord('Active Blank', null);
        Chatbot_Instruction__c whitespace = makeRecord('Active Whitespace', '   ');
        Chatbot_Instruction__c alwaysOn = makeRecord('Always On Blank', null);
        alwaysOn.Always_Include__c = true;
        Chatbot_Instruction__c proxyInjected = makeRecord('Proxy Injected Blank', null);
        proxyInjected.Proxy_Injected_Instruction__c = true;
        Chatbot_Instruction__c inactive = makeRecord('Inactive Blank', null);
        inactive.Active__c = false;
        Chatbot_Instruction__c described = makeRecord('Active Described', 'Drafts a thing. Give it the source file.');

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(new List<Chatbot_Instruction__c>{
            blank, whitespace, alwaysOn, proxyInjected, inactive, described
        }, false);
        Test.stopTest();

        assertRefusedByRule(results[0], 'Active record with a blank description');
        assertRefusedByRule(results[1], 'Active record with a whitespace-only description');
        System.assert(results[2].isSuccess(), 'Always Include needs no description: ' + results[2].getErrors());
        System.assert(results[3].isSuccess(), 'Proxy Injected needs no description: ' + results[3].getErrors());
        System.assert(results[4].isSuccess(), 'An inactive record needs no description: ' + results[4].getErrors());
        System.assert(results[5].isSuccess(), 'A described active record saves: ' + results[5].getErrors());
    }

    @isTest
    static void clearingDescriptionOnListedSkillIsRefused() {
        Chatbot_Instruction__c skill = makeRecord('Listed Skill', 'Drafts a thing. Give it the source file.');
        insert skill;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Chatbot_Instruction__c(Id = skill.Id, Library_Description__c = null),
            false
        );
        Test.stopTest();

        assertRefusedByRule(result, 'Clearing the description');
        System.assertNotEquals(null, [SELECT Library_Description__c FROM Chatbot_Instruction__c WHERE Id = :skill.Id].Library_Description__c,
            'The stored description must be unchanged');
    }

    @isTest
    static void makingBlankRecordListedIsRefused() {
        Chatbot_Instruction__c inactive = makeRecord('Inactive Blank', null);
        inactive.Active__c = false;
        Chatbot_Instruction__c alwaysOn = makeRecord('Always On Blank', null);
        alwaysOn.Always_Include__c = true;
        Chatbot_Instruction__c proxyInjected = makeRecord('Proxy Injected Blank', null);
        proxyInjected.Proxy_Injected_Instruction__c = true;
        insert new List<Chatbot_Instruction__c>{ inactive, alwaysOn, proxyInjected };

        Test.startTest();
        List<Database.SaveResult> results = Database.update(new List<Chatbot_Instruction__c>{
            new Chatbot_Instruction__c(Id = inactive.Id, Active__c = true),
            new Chatbot_Instruction__c(Id = alwaysOn.Id, Always_Include__c = false),
            new Chatbot_Instruction__c(Id = proxyInjected.Id, Proxy_Injected_Instruction__c = false)
        }, false);
        Test.stopTest();

        assertRefusedByRule(results[0], 'Activating a blank record');
        assertRefusedByRule(results[1], 'Unticking Always Include on a blank record');
        assertRefusedByRule(results[2], 'Unticking Proxy Injected on a blank record');
    }

    @isTest
    static void reorderAndUnrelatedEditsSave() {
        Chatbot_Instruction__c listed = makeRecord('Listed Skill', 'Drafts a thing. Give it the source file.');
        Chatbot_Instruction__c inactive = makeRecord('Inactive Blank', null);
        inactive.Active__c = false;
        Chatbot_Instruction__c alwaysOn = makeRecord('Always On Blank', null);
        alwaysOn.Always_Include__c = true;
        insert new List<Chatbot_Instruction__c>{ listed, inactive, alwaysOn };
        Map<Id, Decimal> indexBefore = new Map<Id, Decimal>();
        for (Chatbot_Instruction__c row : [SELECT Id, Index__c FROM Chatbot_Instruction__c]) {
            indexBefore.put(row.Id, row.Index__c);
        }

        Test.startTest();
        // Position 1 makes the re-index trigger shift (update) every sibling.
        Chatbot_Instruction__c first = makeRecord('New First Skill', 'Does a thing. Give it a file.');
        first.Index__c = 1;
        Database.SaveResult reorder = Database.insert(first, false);
        Database.SaveResult unrelated = Database.update(new Chatbot_Instruction__c(Id = listed.Id, Usage__c = 'Edited usage'), false);
        Test.stopTest();

        System.assert(reorder.isSuccess(), 'A reorder must save: ' + reorder.getErrors());
        System.assert(unrelated.isSuccess(), 'An unrelated edit of a listed skill must save: ' + unrelated.getErrors());
        for (Chatbot_Instruction__c row : [SELECT Id, Index__c FROM Chatbot_Instruction__c WHERE Id IN :indexBefore.keySet()]) {
            System.assertEquals(indexBefore.get(row.Id) + 1, row.Index__c, 'Every sibling should have shifted down one place');
        }
    }
}
