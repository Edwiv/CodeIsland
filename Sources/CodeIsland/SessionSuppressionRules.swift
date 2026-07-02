import Foundation
import CodeIslandCore

enum SessionSuppressionRules {
    static func patterns(from raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func fields(from event: HookEvent) -> [String] {
        var result: [String] = [event.eventName]
        if let sessionId = event.sessionId { result.append(sessionId) }
        collectStrings(from: event.rawJSON, into: &result)
        return result
    }

    static func eventMatches(_ event: HookEvent, patternsRaw: String) -> Bool {
        fieldsMatch(fields(from: event), patternsRaw: patternsRaw)
    }

    static func fields(from persisted: PersistedSession) -> [String] {
        [
            persisted.sessionId,
            persisted.source,
            persisted.cwd,
            persisted.model,
            persisted.sessionTitle,
            persisted.providerSessionId,
            persisted.lastUserPrompt,
            persisted.lastAssistantMessage,
            persisted.termApp,
            persisted.termBundleId,
        ].compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
    }

    static func persistedSessionMatches(_ persisted: PersistedSession, patternsRaw: String) -> Bool {
        fieldsMatch(fields(from: persisted), patternsRaw: patternsRaw)
    }

    static func fieldsMatch(_ fields: [String], patternsRaw: String) -> Bool {
        let parsedPatterns = patterns(from: patternsRaw)
        guard !parsedPatterns.isEmpty else { return false }

        for field in fields where !field.isEmpty {
            for pattern in parsedPatterns {
                if field.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func collectStrings(from value: Any, into result: inout [String], depth: Int = 0) {
        guard depth < 4 else { return }
        if let string = value as? String {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(string)
            }
            return
        }
        if let dict = value as? [String: Any] {
            for item in dict.values {
                collectStrings(from: item, into: &result, depth: depth + 1)
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                collectStrings(from: item, into: &result, depth: depth + 1)
            }
        }
    }
}
