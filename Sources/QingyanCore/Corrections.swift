import Foundation

/// The one shared piece of "learn from corrections": a pure string diff that says whether what
/// happened in the field after put wrote `written` into it looks like the user corrected a word.
/// `before`/`after` are the field read a second after the write, split at the cursor — the write
/// is anchored by the cursor sitting right after it; `current` is the field read again later.
/// Nothing here touches the network; the caller decides what to offer.
public enum CorrectionLearning {
    /// The word the written text was changed into, or nil when the change is not a word
    /// correction inside what was written (an edit elsewhere, a deletion, appended typing,
    /// punctuation only, more than one token, or a replacement too large or too small).
    public static func suggestion(before: String, after: String, written: String, current: String) -> String? {
        let w = Array(written), b = Array(before + after), c = Array(current)
        guard !w.isEmpty, before.hasSuffix(written) else { return nil }
        let ws = before.count - w.count, we = before.count
        var p = 0
        while p < min(b.count, c.count), b[p] == c[p] { p += 1 }
        var s = 0
        while s < min(b.count, c.count) - p, b[b.count - 1 - s] == c[c.count - 1 - s] { s += 1 }
        let oldEnd = b.count - s, newEnd = c.count - s
        guard oldEnd >= p, newEnd >= p,
              oldEnd - p <= 20, newEnd - p >= 1, newEnd - p <= 30,
              ws <= p, oldEnd <= we,
              oldEnd > p || (ws < p && p < we) else { return nil }
        guard !c[p..<newEnd].contains("\n") else { return nil }
        // The change is a word correction only when the word it leaves behind differs from the
        // word that stood there before — a punctuation change widens to the same word.
        guard let new = word(at: p..<newEnd, in: c),
              word(at: p..<oldEnd, in: b) != new else { return nil }
        return new
    }

    /// The changed range in `text` widened to the word around it — only while it holds no
    /// ideographic character, where the range itself is the word — then trimmed down to letters
    /// and numbers. nil when nothing word-like remains or the word cannot be an entry: one token
    /// of 2…40 characters — letters, numbers or marks, with the joiners "-", "'", "’", "." and
    /// "·" allowed inside — that contains a letter or a number.
    private static func word(at range: Range<Int>, in text: [Character]) -> String? {
        var lo = range.lowerBound, hi = range.upperBound
        if !text[range].contains(where: ideographic) {
            while lo > 0, widens(text[lo - 1]) { lo -= 1 }
            while hi < text.count, widens(text[hi]) { hi += 1 }
        }
        while lo < hi, !(text[lo].isLetter || text[lo].isNumber) { lo += 1 }
        while hi > lo, !(text[hi - 1].isLetter || text[hi - 1].isNumber) { hi -= 1 }
        let word = text[lo..<hi]
        guard word.count >= 2, word.count <= 40,
              word.contains(where: { $0.isLetter || $0.isNumber }),
              word.allSatisfy({ $0.isLetter || $0.isNumber || mark($0) || joiners.contains($0) })
        else { return nil }
        return String(word)
    }

    /// What may join the parts of one word, such as the hyphen in "e-mail".
    private static let joiners: Set<Character> = ["-", "'", "’", ".", "·"]

    private static func ideographic(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    /// A combining mark, allowed inside a word so an accented name can be an entry.
    private static func mark(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            let category = $0.properties.generalCategory
            return category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
        }
    }

    /// A letter or digit the changed range may spread over; an ideographic neighbour is part of
    /// its own word, not of a latin one.
    private static func widens(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && !ideographic(c)
    }
}
