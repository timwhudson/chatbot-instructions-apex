/**
 * ChatbotInstructionRequiredSkillsTest
 *
 * Tests for the "Required Skills" text field (Required_Skill_Names__c), written
 * by ChatbotInstructionRequiredSkills from RequiredSkillTrigger and
 * ChatbotInstructionTrigger.
 *
 * Scenarios:
 *   1. Rows added in one bulk insert -> "A, B" (A-Z); removing one -> "B";
 *      removing the last -> blank; undeleting it -> back. The skill's
 *      Version_Number__c never moves (only text/fingerprint changes count).
 *   2. Re-pointing a row to another required skill rewrites the list.
 *   3. Renaming a required skill rewrites every requirer's list, including a
 *      capitals-only rename and a rename where the requirer is renamed in the
 *      SAME save (it updates a record that is in the running trigger).
 *   4. A new record (e.g. a clone) never keeps a pasted-in list.
 *   5. A list longer than 255 characters is cut with "...".
 *   6. Deleting a requiring skill (cascade-deletes its rows) raises nothing.
 *   7. Restoring a skill from the Recycle Bin after a required skill was renamed
 *      shows the new name (its rows come back without RequiredSkillTrigger).
 *
 * Test data respects the org's validation rules (see
 * ChatbotInstructionRestrictionTest's header): Usage__c, Instruction_Text__c and
 * Library_Description__c on every active, router-choosable record. Required
 * skills must be active, not Always Include / Proxy Injected (lookup filter).
 */
@isTest
private class ChatbotInstructionRequiredSkillsTest {

    // ── Helper: an ordinary text skill that passes the org's rules ──
    private static Chatbot_Instruction__c makeSkill(String name) {
        return new Chatbot_Instruction__c(
            Name = name,
            Usage__c = 'Test usage',
            Instruction_Text__c = 'Test instruction text',
            Library_Description__c = 'Test library description.'
        );
    }

    // ── Helper: one Required Skill row ──
    private static Required_Skill__c link(Id skillId, Id requiredId) {
        return new Required_Skill__c(Instruction__c = skillId, Required_Instruction__c = requiredId);
    }

    // ── Helper: the stored list on one skill ──
    private static String listOf(Id skillId) {
        return [SELECT Required_Skill_Names__c FROM Chatbot_Instruction__c WHERE Id = :skillId]
            .Required_Skill_Names__c;
    }

    // ══════════════════════════════════════════════════════════════════
    //  1. Add, remove, remove last, undelete; version untouched
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void followsRowsAddedRemovedAndUndeleted() {
        Chatbot_Instruction__c parent = makeSkill('Parent Skill');
        Chatbot_Instruction__c alpha = makeSkill('Alpha Skill');
        Chatbot_Instruction__c beta = makeSkill('Beta Skill');
        insert new List<Chatbot_Instruction__c>{ parent, alpha, beta };
        Decimal versionBefore = [SELECT Version_Number__c FROM Chatbot_Instruction__c WHERE Id = :parent.Id]
            .Version_Number__c;

        // Inserted in Z-A order on purpose: the list is A-Z whatever the order.
        Required_Skill__c betaRow = link(parent.Id, beta.Id);
        Required_Skill__c alphaRow = link(parent.Id, alpha.Id);
        insert new List<Required_Skill__c>{ betaRow, alphaRow };
        System.assertEquals('Alpha Skill, Beta Skill', listOf(parent.Id));

        delete alphaRow;
        System.assertEquals('Beta Skill', listOf(parent.Id));

        delete betaRow;
        System.assertEquals(null, listOf(parent.Id), 'No rows -> blank');

        undelete betaRow;
        System.assertEquals('Beta Skill', listOf(parent.Id));

        System.assertEquals(
            versionBefore,
            [SELECT Version_Number__c FROM Chatbot_Instruction__c WHERE Id = :parent.Id].Version_Number__c,
            'A Required Skills change is not a new skill version'
        );
        System.assertEquals(null, listOf(alpha.Id), 'A required skill itself lists nothing');
    }

    // ══════════════════════════════════════════════════════════════════
    //  2. Re-pointing a row rewrites the list
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void followsARepointedRow() {
        Chatbot_Instruction__c parent = makeSkill('Parent Skill');
        Chatbot_Instruction__c first = makeSkill('First Skill');
        Chatbot_Instruction__c second = makeSkill('Second Skill');
        insert new List<Chatbot_Instruction__c>{ parent, first, second };
        Required_Skill__c row = link(parent.Id, first.Id);
        insert row;

        row.Required_Instruction__c = second.Id;
        update row;
        System.assertEquals('Second Skill', listOf(parent.Id));
    }

    // ══════════════════════════════════════════════════════════════════
    //  3. Renames reach every requirer (capitals-only and same-save too)
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void followsRenamesOfRequiredSkills() {
        Chatbot_Instruction__c parentOne = makeSkill('Parent One');
        Chatbot_Instruction__c parentTwo = makeSkill('Parent Two');
        Chatbot_Instruction__c shared = makeSkill('Drafting emails');
        insert new List<Chatbot_Instruction__c>{ parentOne, parentTwo, shared };
        insert new List<Required_Skill__c>{ link(parentOne.Id, shared.Id), link(parentTwo.Id, shared.Id) };

        // Capitals only: Apex's `==` would call these equal; the list must still change.
        update new Chatbot_Instruction__c(Id = shared.Id, Name = 'Drafting Emails');
        System.assertEquals('Drafting Emails', listOf(parentOne.Id));
        System.assertEquals('Drafting Emails', listOf(parentTwo.Id));

        // Same save renames the required skill AND one of its requirers.
        update new List<Chatbot_Instruction__c>{
            new Chatbot_Instruction__c(Id = shared.Id, Name = 'Email Drafting'),
            new Chatbot_Instruction__c(Id = parentOne.Id, Name = 'Parent One Renamed')
        };
        System.assertEquals('Email Drafting', listOf(parentOne.Id));
        System.assertEquals('Email Drafting', listOf(parentTwo.Id));
        System.assertEquals('Parent One Renamed',
            [SELECT Name FROM Chatbot_Instruction__c WHERE Id = :parentOne.Id].Name);
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. A new record (clone) never keeps a pasted-in list
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void newRecordStartsBlank() {
        Chatbot_Instruction__c copy = makeSkill('Cloned Skill');
        copy.Required_Skill_Names__c = 'Stale Name From The Original';
        insert copy;
        System.assertEquals(null, listOf(copy.Id));
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. Over 255 characters -> cut with "..."
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void longListIsCutToFieldLength() {
        Chatbot_Instruction__c parent = makeSkill('Parent Skill');
        List<Chatbot_Instruction__c> required = new List<Chatbot_Instruction__c>();
        for (Integer i = 0; i < 5; i++) {
            // 5 names of 70 characters = 360 characters with separators
            required.add(makeSkill(('Required Skill ' + i + ' ').rightPad(70, 'x')));
        }
        List<Chatbot_Instruction__c> all = new List<Chatbot_Instruction__c>{ parent };
        all.addAll(required);
        insert all;
        List<Required_Skill__c> rows = new List<Required_Skill__c>();
        for (Chatbot_Instruction__c rec : required) {
            rows.add(link(parent.Id, rec.Id));
        }
        insert rows;

        String stored = listOf(parent.Id);
        System.assertEquals(255, stored.length());
        System.assert(stored.startsWith('Required Skill 0 '), stored);
        System.assert(stored.endsWith('...'), stored);
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. Deleting the requiring skill (cascade) raises nothing
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void deletingTheRequiringSkillIsClean() {
        Chatbot_Instruction__c parent = makeSkill('Parent Skill');
        Chatbot_Instruction__c required = makeSkill('Required Skill');
        insert new List<Chatbot_Instruction__c>{ parent, required };
        insert link(parent.Id, required.Id);

        delete parent;
        System.assertEquals(0, [SELECT COUNT() FROM Required_Skill__c WHERE Required_Instruction__c = :required.Id]);
        System.assertEquals(null, listOf(required.Id));
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. Recycle Bin restore after a rename shows the new name
    // ══════════════════════════════════════════════════════════════════
    @isTest
    static void restoredSkillShowsCurrentNames() {
        Chatbot_Instruction__c parent = makeSkill('Parent Skill');
        Chatbot_Instruction__c required = makeSkill('Old Name');
        insert new List<Chatbot_Instruction__c>{ parent, required };
        insert link(parent.Id, required.Id);

        delete parent;
        update new Chatbot_Instruction__c(Id = required.Id, Name = 'New Name');
        undelete parent;
        System.assertEquals('New Name', listOf(parent.Id));
    }
}
