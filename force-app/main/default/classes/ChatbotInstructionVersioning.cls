/**
 * ChatbotInstructionVersioning
 *
 * Skill versioning (CFO Bot plan "Skill version control", decisions F1/G1/G2):
 * every firm skill carries a content version number and the date that version
 * took effect. Salesforce is the single source of truth for firm versions; the
 * LiteLLM proxy reads both fields and CFO Bot shows them.
 *
 * RULES (called from ChatbotInstructionTrigger, BEFORE insert / BEFORE update):
 *   - A new record (including a clone or a Data Loader insert) starts at
 *     Version 1, dated now — whatever values the insert carried.
 *   - An edit keeps the old number, plus one (dated now) only when the content
 *     REALLY changed: Instruction_Text__c or Bundle_Fingerprint__c. Re-ordering,
 *     descriptions, Usage, Active, positions and every other field never count.
 *     A value an API call / Data Loader / rollback file tries to set is
 *     overwritten, so a number can never go down (G2: no copies of old firm
 *     text are kept, so a restore of old text is simply the next number).
 *   - A blank old number (a record that somehow missed the backfill) is a
 *     "first stamp": Version 1, dated now — never an error.
 *
 * "REALLY CHANGED":
 *   - Text: compared exactly first (String.equals — Apex's `!=` on Strings
 *     ignores case, so it is never used here). Only when that differs are the
 *     cleaned-up forms compared: line endings made LF, trailing spaces/tabs
 *     removed per line, leading/trailing blank space removed — the same clean-up
 *     as CFO Bot's text fingerprint, except Unicode normalization (Apex has no
 *     NFC). So a change in accent encoding alone raises the version — harmless.
 *   - Fingerprint: the pasted value is trimmed and lower-cased first (the
 *     Bundle_Fingerprint_Format validation rule then checks its shape), so a
 *     re-paste in capitals or with a trailing space is not a new version.
 *
 * The trigger's recursion guard (ChatbotInstructionIndexingService.isRunning)
 * skips this during the index rebuild's sibling updates; those only change
 * Index__c, which never counts.
 */
public with sharing class ChatbotInstructionVersioning {

    // ── BEFORE INSERT ────────────────────────────────────────────────
    public static void handleBeforeInsert(List<Chatbot_Instruction__c> newRecords) {
        Datetime now = Datetime.now();
        for (Chatbot_Instruction__c rec : newRecords) {
            rec.Bundle_Fingerprint__c = cleanFingerprint(rec.Bundle_Fingerprint__c);
            rec.Version_Number__c = 1;
            rec.Version_Date__c = now;
        }
    }

    // ── BEFORE UPDATE ────────────────────────────────────────────────
    public static void handleBeforeUpdate(
        List<Chatbot_Instruction__c> newRecords,
        Map<Id, Chatbot_Instruction__c> oldMap
    ) {
        Datetime now = Datetime.now();
        for (Chatbot_Instruction__c rec : newRecords) {
            Chatbot_Instruction__c old = oldMap.get(rec.Id);
            rec.Bundle_Fingerprint__c = cleanFingerprint(rec.Bundle_Fingerprint__c);

            // First stamp: no number yet (missed the backfill).
            if (old.Version_Number__c == null) {
                rec.Version_Number__c = 1;
                rec.Version_Date__c = now;
                continue;
            }

            Boolean changed =
                textChanged(old.Instruction_Text__c, rec.Instruction_Text__c)
                || !sameString(old.Bundle_Fingerprint__c, rec.Bundle_Fingerprint__c);
            if (changed) {
                rec.Version_Number__c = old.Version_Number__c + 1;
                rec.Version_Date__c = now;
            } else {
                // Undo anything an API call / Data Loader tried to set.
                rec.Version_Number__c = old.Version_Number__c;
                rec.Version_Date__c = old.Version_Date__c;
            }
        }
    }

    // ── Helpers (public for the test class) ─────────────────────────

    /** Trimmed and lower-cased; blank becomes null. */
    public static String cleanFingerprint(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.trim().toLowerCase();
    }

    /** True when the instruction text really changed (see class comment). */
    public static Boolean textChanged(String oldText, String newText) {
        if (sameString(oldText, newText)) {
            return false;
        }
        return !sameString(normalize(oldText), normalize(newText));
    }

    /** Null-safe, case-SENSITIVE equality (Apex `==` on Strings ignores case). */
    public static Boolean sameString(String a, String b) {
        if (a == null || b == null) {
            return a == null && b == null;
        }
        return a.equals(b);
    }

    /**
     * CRLF / CR -> LF, trailing spaces and tabs removed from every line,
     * leading and trailing spaces, tabs and newlines removed from the whole
     * text. Plain indexOf/substring loops, no regex and no String.split (which
     * is a regex): Apex regexes can fail with "Regex too complicated" on long
     * inputs, and Instruction_Text__c holds up to 131,072 characters.
     */
    public static String normalize(String text) {
        if (text == null) {
            return '';
        }
        String unified = text.replace('\r\n', '\n').replace('\r', '\n');
        List<String> cleaned = new List<String>();
        Integer lineStart = 0;
        while (true) {
            Integer lineEnd = unified.indexOf('\n', lineStart);
            String line = lineEnd < 0 ? unified.substring(lineStart) : unified.substring(lineStart, lineEnd);
            Integer keep = line.length();
            while (keep > 0 && isSpaceOrTab(line.substring(keep - 1, keep))) {
                keep--;
            }
            cleaned.add(line.substring(0, keep));
            if (lineEnd < 0) {
                break;
            }
            lineStart = lineEnd + 1;
        }
        String joined = String.join(cleaned, '\n');
        Integer startIndex = 0;
        Integer stopIndex = joined.length();
        while (startIndex < stopIndex && isBlankChar(joined.substring(startIndex, startIndex + 1))) {
            startIndex++;
        }
        while (stopIndex > startIndex && isBlankChar(joined.substring(stopIndex - 1, stopIndex))) {
            stopIndex--;
        }
        return joined.substring(startIndex, stopIndex);
    }

    private static Boolean isSpaceOrTab(String c) {
        return c == ' ' || c == '\t';
    }

    private static Boolean isBlankChar(String c) {
        return c == ' ' || c == '\t' || c == '\n';
    }
}
