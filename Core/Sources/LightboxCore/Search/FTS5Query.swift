import Foundation

/// Turns arbitrary user text into a safe FTS5 MATCH expression.
///
/// FTS5 has a query grammar of its own: `*`, `^`, `-`, `:`, `NEAR`, `AND`,
/// `OR`, and double quotes are all syntax. Passing user text through untouched
/// means an unbalanced quote throws inside SQLite and a stray operator silently
/// changes what the user asked for. Reducing input to alphanumeric tokens and
/// quoting each one means user text can only ever be terms.
public enum FTS5Query {
    public static func sanitize(_ raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        // Quotes are doubled defensively. Tokenization already removed them,
        // but this must stay correct if the token rule is ever loosened.
        let quoted = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }

        // Only the last token is a prefix match: the user is still typing it.
        var terms = quoted
        terms[terms.count - 1] += "*"
        return terms.joined(separator: " AND ")
    }
}
