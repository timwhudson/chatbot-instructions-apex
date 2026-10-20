/**
 * ChatbotInstructionRestrictionTest
 *
 * Tests for position-restricted skills on Chatbot_Instruction__c:
 *   - the Apex guard (ChatbotInstructionRestrictionGuard, run from
 *     ChatbotInstructionTrigger before update), and
 *   - the three validation rules shipped with it, so a validate/deploy proves
 *     they compile AND behave against the real org rules.
 *
 * Scenarios:
 *   1. Restricting a skill required through a Required_Skill__c row is refused,
 *      and the message names the requiring skill.
 *   2. Restricting a skill required through the legacy Instruction_Dependency__c
 *      lookup is refused, and the message names the requiring skill.
 *   3. An unrelated edit of an already-required skill still saves (the guard
 *      only acts on blank -> filled).
 *   4. Restricting a skill nobody requires saves, and the formula
 *      Is_Position_Restricted__c turns TRUE.
 *   5. Bulk save with partial success: only the required skill is refused; a
 *      link added in the SAME save is caught too.
 *   6. Validation rule Cannot_Require_Restricted_Skill (Required_Skill__c,
 *      cross-object formula through Required_Instruction__r) refuses a new row.
 *   7. Validation rule Cannot_Depend_On_Restricted_Skill does NOT fire on the
 *      re-index trigger's sibling updates (its ISCHANGED guard), but DOES fire
 *      when the lookup itself is set.
 *   8. Validation rule Restricted_Skill_Must_Be_Plain_Text refuses restricting an
 *      Always Include, a Proxy Injected and a Packaged Skill ID record.
 *   9. Recycle Bin: a requirement whose requiring skill, Required_Skill__c row
 *      or legacy linker is deleted (still in the bin) still blocks, because an
 *      undelete would bring it back without re-running validation rules.
 *      Known limit: ALL ROWS also returns rows emptied from the bin until
 *      Salesforce physically purges them (a probe on 2026-10-20 showed emptied
 *      rows still returned in the same transaction, with no field to tell them
 *      apart), so a just-emptied requirement keeps blocking for a while. That
 *      fails closed, and no test can observe the asynchronous purge.
 *  10. Board Notes' live shape: a skill that ITSELF requires other skills
 *      (outgoing Required_Skill__c row + legacy link) can be restricted.
 *
 * Test data respects the org's existing validation rules (see commit b0a7018):
 *   Usage_Required (Usage__c when not Always Include / Proxy Injected) and
 *   Instruction_Text_Required (Instruction_Text__c always).
 */
@isTest
private class ChatbotInstructionRestrictionTest {

    // Two real TCCFO_Positions values (the field is a restricted picklist).
    private static final String POSITIONS = 'Accounting Manager;Partner';

    // ── Helper: an ordinary text skill that passes the org's rules ──
    private static Chatbot_Instruction__c makeSkill(String name) {
        return new Chatbot_Instruction__c(
            Name = name,
            Usage__c = 'Test usage',
            Instruction_Text__c = 'Test instruction text'
        );
    }

    // ── Helper: try to restrict one record; return the save result ──
    private static Database.SaveResult tryRestrict(Id skillId) {
        return Database.update(
            new Chatbot_Instruction__c(Id = skillId, Allowed_Positions__c = POSITIONS),
            false
        );
    }

    // ── Helper: the first error message of a failed save ──
    private static String firstError(Database.SaveResult result) {
        System.assert(!result.isSuccess(), 'Expected the save to be refused');
        return result.getErrors()[0].getMessage();
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Required through a Required_Skill__c row -> refused, names requirer
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void refusesWhenRequiredByJunctionRow() {
        Chatbot_Instruction__c target = makeSkill('Target Skill');
        Chatbot_Instruction__c requirer = makeSkill('Junction Requirer');
        insert new List<Chatbot_Instruction__c>{ target, requirer };
        insert new Required_Skill__c(Instruction__c = requirer.Id, Required_Instruction__c = target.Id);

        Test.startTest();
        Database.SaveResult result = tryRestrict(target.Id);
        Test.stopTest();

        String message = firstError(result);
        System.assert(message.contains('"Junction Requirer"'), 'Message should name the requiring skill: ' + message);
        System.assert(message.startsWith('Can\'t restrict this skill'), 'Unexpected message: ' + message);
        Chatbot_Instruction__c reloaded = [SELECT Allowed_Positions__c FROM Chatbot_Instruction__c WHERE Id = :target.Id];
        System.assertEquals(null, reloaded.Allowed_Positions__c, 'Target must stay unrestricted');
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Required through the legacy lookup -> refused, names requirer
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void refusesWhenRequiredByLegacyLookup() {
        Chatbot_Instruction__c target = makeSkill('Target Skill');
        insert target;
        Chatbot_Instruction__c requirer = makeSkill('Legacy Requirer');
        requirer.Instruction_Dependency__c = target.Id;
        insert requirer;

        Test.startTest();
        Database.SaveResult result = tryRestrict(target.Id);
        Test.stopTest();

        String message = firstError(result);
        System.assert(message.contains('"Legacy Requirer"'), 'Message should name the requiring skill: ' + message);
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Unrelated edit of an already-required skill still saves
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void unrelatedEditOfRequiredSkillSaves() {
        Chatbot_Instruction__c target = makeSkill('Target Skill');
        Chatbot_Instruction__c junctionRequirer = makeSkill('Junction Requirer');
        insert new List<Chatbot_Instruction__c>{ target, junctionRequirer };
        insert new Required_Skill__c(Instruction__c = junctionRequirer.Id, Required_Instruction__c = target.Id);
        Chatbot_Instruction__c legacyRequirer = makeSkill('Legacy Requirer');
        legacyRequirer.Instruction_Dependency__c = target.Id;
        insert legacyRequirer;

        Test.startTest();
        target.Usage__c = 'Edited usage';
        Database.SaveResult result = Database.update(target, false);
        Test.stopTest();

        System.assert(result.isSuccess(), 'An edit that does not restrict must save: ' + result.getErrors());
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. Restricting a skill nobody requires saves; formula turns TRUE
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void restrictingUnrequiredSkillSaves() {
        Chatbot_Instruction__c target = makeSkill('Target Skill');
        insert target;

        Test.startTest();
        Database.SaveResult result = tryRestrict(target.Id);
        Test.stopTest();

        System.assert(result.isSuccess(), 'Restricting an unrequired skill must save: ' + result.getErrors());
        Chatbot_Instruction__c reloaded = [
            SELECT Allowed_Positions__c, Is_Position_Restricted__c
            FROM Chatbot_Instruction__c WHERE Id = :target.Id
        ];
        System.assertEquals(POSITIONS, reloaded.Allowed_Positions__c, 'Positions should be stored ;-joined');
        System.assertEquals(true, reloaded.Is_Position_Restricted__c, 'Formula should read TRUE when positions are filled');
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Bulk, partial success: only the required skill is refused;
    //     a legacy link added in the SAME save is caught as well
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void bulkSaveRefusesOnlyRequiredSkills() {
        Chatbot_Instruction__c free = makeSkill('Free Skill');
        Chatbot_Instruction__c required = makeSkill('Required Skill');
        Chatbot_Instruction__c sameSave = makeSkill('Same Save Target');
        Chatbot_Instruction__c requirer = makeSkill('Junction Requirer');
        Chatbot_Instruction__c linker = makeSkill('Same Save Linker');
        insert new List<Chatbot_Instruction__c>{ free, required, sameSave, requirer, linker };
        insert new Required_Skill__c(Instruction__c = requirer.Id, Required_Instruction__c = required.Id);

        Test.startTest();
        List<Database.SaveResult> results = Database.update(new List<Chatbot_Instruction__c>{
            new Chatbot_Instruction__c(Id = free.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = required.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = sameSave.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = linker.Id, Instruction_Dependency__c = sameSave.Id)
        }, false);
        Test.stopTest();

        System.assert(results[0].isSuccess(), 'Free skill should be restricted: ' + results[0].getErrors());
        System.assert(firstError(results[1]).contains('"Junction Requirer"'), 'Required skill must be refused');
        System.assert(firstError(results[2]).contains('"Same Save Linker"'), 'Link added in the same save must be caught');
        // The linker's own save may also be refused (observed in this org: the
        // Cannot_Depend_On_Restricted_Skill rule sees the same-save restriction).
        // What matters is the invariant: no saved link points at a restricted skill.
        System.assertEquals(0, [
            SELECT COUNT() FROM Chatbot_Instruction__c
            WHERE Instruction_Dependency__r.Is_Position_Restricted__c = true
        ], 'No legacy link may point at a restricted skill after the save');
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. VR Cannot_Require_Restricted_Skill: no new junction row may
    //     point at a restricted skill (cross-object formula)
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void junctionRuleRefusesRequiringRestrictedSkill() {
        Chatbot_Instruction__c target = makeSkill('Target Skill');
        Chatbot_Instruction__c requirer = makeSkill('Would-be Requirer');
        target.Allowed_Positions__c = POSITIONS;
        insert new List<Chatbot_Instruction__c>{ target, requirer };

        Test.startTest();
        Database.SaveResult result = Database.insert(
            new Required_Skill__c(Instruction__c = requirer.Id, Required_Instruction__c = target.Id),
            false
        );
        Test.stopTest();

        System.assertEquals('A skill can\'t require a position-restricted skill.', firstError(result));
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. VR Cannot_Depend_On_Restricted_Skill ignores the re-index
    //     trigger's sibling updates, but fires when the lookup is set
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void legacyRuleIgnoresReindexSiblingUpdates() {
        // A legacy link that predates the restriction: create the link first,
        // then restrict the target with the trigger switched off (the
        // recursion guard), the way an edge created before this feature
        // shipped would look.
        Chatbot_Instruction__c target = makeSkill('Target Skill');
        insert target;
        Chatbot_Instruction__c sibling = makeSkill('Old Linked Sibling');
        sibling.Instruction_Dependency__c = target.Id;
        insert sibling;
        ChatbotInstructionIndexingService.isRunning = true;
        update new Chatbot_Instruction__c(Id = target.Id, Allowed_Positions__c = POSITIONS);
        ChatbotInstructionIndexingService.isRunning = false;
        Decimal siblingIndexBefore = [SELECT Index__c FROM Chatbot_Instruction__c WHERE Id = :sibling.Id].Index__c;

        Test.startTest();
        // Inserting at position 1 makes the re-index rebuild update EVERY
        // sibling's Index__c, including the linked one.
        Chatbot_Instruction__c first = makeSkill('New First Skill');
        first.Index__c = 1;
        Database.SaveResult rebuild = Database.insert(first, false);
        // Setting the lookup itself must still be refused.
        Chatbot_Instruction__c newLinker = makeSkill('New Linker');
        newLinker.Instruction_Dependency__c = target.Id;
        Database.SaveResult direct = Database.insert(newLinker, false);
        Test.stopTest();

        System.assert(rebuild.isSuccess(), 'Re-index sibling updates must not trip the rule: ' + rebuild.getErrors());
        Decimal siblingIndexAfter = [SELECT Index__c FROM Chatbot_Instruction__c WHERE Id = :sibling.Id].Index__c;
        System.assertEquals(siblingIndexBefore + 1, siblingIndexAfter, 'The linked sibling should have been re-indexed');
        System.assertEquals('A skill can\'t depend on a position-restricted skill.', firstError(direct));
    }

    // ══════════════════════════════════════════════════════════════════
    //  8. VR Restricted_Skill_Must_Be_Plain_Text: Always Include, Proxy
    //     Injected and Packaged Skill ID records can't be restricted
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void restrictedSkillMustBePlainText() {
        Chatbot_Instruction__c alwaysOn = makeSkill('Always On Instruction');
        alwaysOn.Always_Include__c = true;
        Chatbot_Instruction__c proxyInjected = makeSkill('Proxy Injected Instruction');
        proxyInjected.Proxy_Injected_Instruction__c = true;
        Chatbot_Instruction__c packaged = makeSkill('Packaged Skill');
        packaged.Anthropic_Skill_ID__c = 'skill_test_packaged';
        List<Chatbot_Instruction__c> skills = new List<Chatbot_Instruction__c>{ alwaysOn, proxyInjected, packaged };
        insert skills;

        Test.startTest();
        List<Database.SaveResult> results = Database.update(new List<Chatbot_Instruction__c>{
            new Chatbot_Instruction__c(Id = alwaysOn.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = proxyInjected.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = packaged.Id, Allowed_Positions__c = POSITIONS)
        }, false);
        Test.stopTest();

        for (Integer i = 0; i < results.size(); i++) {
            System.assert(firstError(results[i]).startsWith('Only a plain text skill can be restricted'),
                'Shape rule should refuse ' + skills[i].Name);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  9. Recycle Bin: deleted requirements still block (undelete would
    //     restore them without re-running validation rules)
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void requirementsInRecycleBinStillBlock() {
        // Path 1: the requiring skill is deleted (its junction row goes with it).
        // Path 2: only the Required_Skill__c row is deleted.
        // Path 3: a legacy linker is deleted.
        Chatbot_Instruction__c target1 = makeSkill('Target One');
        Chatbot_Instruction__c target2 = makeSkill('Target Two');
        Chatbot_Instruction__c target3 = makeSkill('Target Three');
        Chatbot_Instruction__c deletedRequirer = makeSkill('Deleted Requirer');
        Chatbot_Instruction__c rowOwner = makeSkill('Row Owner');
        insert new List<Chatbot_Instruction__c>{ target1, target2, target3, deletedRequirer, rowOwner };
        Required_Skill__c row1 = new Required_Skill__c(Instruction__c = deletedRequirer.Id, Required_Instruction__c = target1.Id);
        Required_Skill__c row2 = new Required_Skill__c(Instruction__c = rowOwner.Id, Required_Instruction__c = target2.Id);
        insert new List<Required_Skill__c>{ row1, row2 };
        Chatbot_Instruction__c deletedLinker = makeSkill('Deleted Linker');
        deletedLinker.Instruction_Dependency__c = target3.Id;
        insert deletedLinker;
        delete new List<SObject>{ deletedRequirer, row2, deletedLinker };

        Test.startTest();
        List<Database.SaveResult> results = Database.update(new List<Chatbot_Instruction__c>{
            new Chatbot_Instruction__c(Id = target1.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = target2.Id, Allowed_Positions__c = POSITIONS),
            new Chatbot_Instruction__c(Id = target3.Id, Allowed_Positions__c = POSITIONS)
        }, false);
        Test.stopTest();

        String[] expected = new String[]{ '"Deleted Requirer"', '"Row Owner"', '"Deleted Linker"' };
        for (Integer i = 0; i < results.size(); i++) {
            String message = firstError(results[i]);
            System.assert(message.contains(expected[i]), 'Path ' + (i + 1) + ' should name ' + expected[i] + ': ' + message);
            System.assert(message.contains('(possibly in the Recycle Bin)'), 'Message should mention the bin: ' + message);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  10. Board Notes' live shape: the restricted skill ITSELF requires
    //      other skills (outgoing junction row + legacy link) -> saves
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void restrictingSkillThatRequiresOthersSaves() {
        Chatbot_Instruction__c junctionDependency = makeSkill('Transcript Framework');
        Chatbot_Instruction__c legacyDependency = makeSkill('Legacy Dependency');
        insert new List<Chatbot_Instruction__c>{ junctionDependency, legacyDependency };
        Chatbot_Instruction__c target = makeSkill('Board Notes Shape');
        target.Instruction_Dependency__c = legacyDependency.Id;
        insert target;
        insert new Required_Skill__c(Instruction__c = target.Id, Required_Instruction__c = junctionDependency.Id);

        Test.startTest();
        Database.SaveResult result = tryRestrict(target.Id);
        Test.stopTest();

        System.assert(result.isSuccess(), 'Requiring others must not block restricting: ' + result.getErrors());
    }
}
