/**
 * Trigger: RequiredSkillTrigger
 * Object: Required_Skill__c
 *
 * After any change to a Required Skill row, rewrites the "Required Skills" text
 * field (Required_Skill_Names__c) on the skill(s) the row belongs to.
 * All logic lives in ChatbotInstructionRequiredSkills.
 */
trigger RequiredSkillTrigger on Required_Skill__c (
    after insert, after update, after delete, after undelete
) {
    ChatbotInstructionRequiredSkills.handleRowChanges(Trigger.new, Trigger.old);
}
