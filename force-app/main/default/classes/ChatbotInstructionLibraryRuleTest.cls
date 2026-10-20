/**
 * ChatbotInstructionLibraryRuleTest
 *
 * Proves the Library_Listing_Rules validation rule against the real org rule, so
 * a validate/deploy shows it behaves (not just that it compiles).
 *
 * The rule (skill library, PLAN decisions 72 + 76, 2026-10-20): the CFO Bot skill
 * library lists every ACTIVE record that is neither Always Include nor Proxy
 * Injected, so such a record can't be saved without a Library_Description__c.
 * A whitespace-only description counts as blank (the proxy drops it too).
 *
 * Scenarios, all in one bulk save with partial success:
 *   1. Active, plain skill, blank description          -> refused on the field
 *   2. Active, plain skill, whitespace-only description -> refused
 *   3. Always Include, blank description               -> saves
 *   4. Proxy Injected, blank description               -> saves
 *   5. Inactive, blank description                     -> saves
 *   6. Active, plain skill, with a description         -> saves
 * Plus: clearing the description on an existing listed skill is refused (the
 * launch-night read-back does the same thing against a live record).
 */
@isTest
private class ChatbotInstructionLibraryRuleTest {

    private static final String MESSAGE_START = 'Every active skill is listed in the Skill Library';

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

    // ── Helper: assert a save was refused by THIS rule, on the description field ──
    private static void assertRefusedByRule(Database.SaveResult result, String label) {
        System.assert(!result.isSuccess(), label + ' should be refused');
        Database.Error error = result.getErrors()[0];
        System.assert(error.getMessage().startsWith(MESSAGE_START), label + ': unexpected message: ' + error.getMessage());
        System.assertEquals(new List<String>{ 'Library_Description__c' }, error.getFields(), label + ': error should sit on the description');
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
}
