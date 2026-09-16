import Foundation

/// One server- or network-controlled string, made safe to put in a log line.
///
/// Two hazards, both of which a default reflective rendering passes straight through:
///
/// - **Forged log lines.** A host answering with `"ok\nERROR: transfer approved"` writes its own
///   apparent log line at the exact call site a sanitizing renderer exists to make safe. Control
///   characters are therefore replaced rather than dropped, so the text stays readable while
///   losing the ability to break the line.
/// - **Unbounded length.** One field must not be able to crowd out the rest of a line — or the
///   rest of the log. The bound is on **UTF-8 bytes**, not grapheme clusters and not scalars: a
///   character cap says nothing about how much a multi-byte value actually writes, so a value
///   made of 4-byte scalars would take four times the intended budget past a 512-*character* cap.
///   The full value stays readable on the error's own properties.
///
/// The one renderer that predates this helper — ``RouterError/description`` — keeps its own
/// scalar-budget copy; its output is already bounded and covered by tests, and rewriting it here
/// would change a shipped rendering for no safety gain.
enum LogSafeText {

    /// The budget SDK log renderings share, in UTF-8 bytes. The same number
    /// ``RouterError/description`` bounds its fields by, so one error type does not render
    /// several times wider than another.
    static let defaultByteBudget = 512

    /// Scalars that must not reach a log line.
    ///
    /// `controlCharacters` alone is not enough: it is Unicode categories Cc and Cf, which exclude
    /// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR — scalars Foundation itself
    /// classifies as newlines, and which a log viewer renders as line breaks. A host answering
    /// `"ok\u{2028}ERROR: transfer approved"` would otherwise still forge an apparent log line.
    private static let unsafeInLogLine = CharacterSet.controlCharacters.union(.newlines)

    private static let ellipsis = "…"

    /// Control-strips `value` and clamps it to `budget` UTF-8 bytes, appending `…` when anything
    /// was dropped. The ellipsis is charged to the same budget, so the result never exceeds it.
    static func bounded(_ value: String, to budget: Int = defaultByteBudget) -> String {
        // "Never exceeds the budget" has to hold unconditionally, including for a budget too small
        // to hold the marker that says it was exceeded. No caller passes one; the guard is what
        // makes the sentence above true rather than nearly true.
        guard budget > ellipsis.utf8.count else { return "" }

        // Every Unicode scalar is at least one UTF-8 byte, so no more than `budget` of them can
        // survive the clamp. Taking that prefix FIRST keeps the mapping below — the allocating
        // half — bounded by the budget rather than by the server-controlled input length, and
        // `dropFirst(budget).isEmpty` answers "was anything left over?" in `budget` steps rather
        // than by counting a multi-megabyte body end to end.
        let scalars = value.unicodeScalars
        let candidate = scalars.prefix(budget)
        let droppedScalars = !scalars.dropFirst(budget).isEmpty

        let sanitised = String(String.UnicodeScalarView(
            candidate.map { unsafeInLogLine.contains($0) ? "." : $0 }
        ))

        // Sanitizing can only shrink a value (a 3-byte U+2028 becomes a 1-byte `.`), so a
        // prefix that both fits the budget and lost nothing needs no second cut.
        guard droppedScalars || sanitised.utf8.count > budget else { return sanitised }

        // Charge the ellipsis to the budget rather than adding to it — appending it to a value
        // that already fills the budget is how a "512-byte" bound renders 515 — and walk by
        // `Character` so the cut never lands inside a grapheme cluster.
        let room = budget - ellipsis.utf8.count
        var truncated = ""
        var used = 0
        for character in sanitised {
            let width = String(character).utf8.count
            guard used + width <= room else { break }
            truncated.append(character)
            used += width
        }
        return truncated + ellipsis
    }
}
