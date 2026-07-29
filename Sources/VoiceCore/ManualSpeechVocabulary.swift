import Foundation

public enum ManualSpeechVocabulary {
    /// Locale-independent on purpose: `.current` case folding is what makes a
    /// Turkish user's dotted and dotless I stop matching, so the same vocabulary
    /// would deduplicate differently after a region change.
    private static func deduplicationIdentity(of term: String) -> String {
        term.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }

    /// Parses an explicit comma- or newline-delimited list while preserving the
    /// user's spelling and first-seen order.
    public static func terms(from text: String, limit: Int = 50) -> [String] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var terms: [String] = []
        for component in text.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let term = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            guard seen.insert(deduplicationIdentity(of: term)).inserted else { continue }
            terms.append(term)
            if terms.count == limit {
                break
            }
        }
        return terms
    }

    public static func merge(
        preferredTerms: [String],
        projectTerms: [String],
        limit: Int = 100
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var merged: [String] = []
        for term in preferredTerms + projectTerms {
            guard !term.isEmpty,
                seen.insert(deduplicationIdentity(of: term)).inserted
            else { continue }
            merged.append(term)
            if merged.count == limit {
                break
            }
        }
        return merged
    }
}
