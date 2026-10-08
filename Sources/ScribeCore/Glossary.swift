import Foundation

/// Словарь терминов и имён: исправляет типичные ошибки распознавания в готовом тексте.
///
/// Формат файла — строка на термин; через «=» перечисляются ошибочные варианты, которые заменяются на термин:
///
///     # комментарий
///     Slack = слак, слаке, Slag
///     Иван Петров, Мария         ← без «=»: только выравнивает регистр («иван» → «Иван»)
///     ASO-шник* = осошник*       ← «*» — любое окончание, оно переносится: «осошников» → «ASO-шников»
///
/// Замена — целыми словами без учёта регистра. Термины с заглавными буквами сами по себе тоже выравнивают регистр;
/// термины только из строчных так не работают (иначе «Релиз» в начале предложения стал бы «релиз»).
///
/// В подсказку модели словарь НЕ подаётся: на созвоне это вдвое замедлило распознавание и увеличило пропуски фраз
/// (4 из 32 предложений против 1), а исправить написание терминов замена после распознавания может и так.
public struct Glossary: Sendable {
    public private(set) var terms: [String] = []
    /// term — на что заменить; keepEnding — термин со «*»: к нему добавляется окончание исходного слова.
    private var replacements: [(pattern: NSRegularExpression, term: String, keepEnding: Bool)] = []

    public init(_ text: String = "") {
        var pairs: [(variant: String, term: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let term = parts.first, !term.isEmpty else { continue }
            // Строка без «=» может перечислять несколько терминов через запятую.
            let lineTerms = parts.count == 1
                ? term.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : [term]
            for t in lineTerms {
                terms.append(t)
                if t != t.lowercased() { pairs.append((t, t)) }  // выравнивание регистра: «петров» → «Петров»
            }
            if parts.count == 2 {
                for variant in parts[1].split(separator: ",") {
                    let v = variant.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty, v.caseInsensitiveCompare(term) != .orderedSame { pairs.append((v, term)) }
                }
            }
        }
        // Длинные варианты раньше коротких: «тик ток» должен замениться целиком, а не по частям.
        replacements = pairs.sorted { $0.variant.count > $1.variant.count }.compactMap { pair in
            // «осошник*» — любое окончание: «осошники», «осошников»…
            let wildcard = pair.variant.hasSuffix("*")
            let stem = wildcard ? String(pair.variant.dropLast()) : pair.variant
            let escaped = NSRegularExpression.escapedPattern(for: stem)
                .replacingOccurrences(of: " ", with: "\\s+")  // «тик  ток», «тик\nток» — тоже совпадение
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)\(wildcard ? "(\\p{L}*)" : "")(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            // «ASO-шник*» — окончание переносится из исходного слова; термин без «*» заменяет слово целиком.
            let keepEnding = wildcard && pair.term.hasSuffix("*")
            return (re, keepEnding ? String(pair.term.dropLast()) : pair.term, keepEnding)
        }
    }

    public init(contentsOf url: URL) {
        self.init((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Заменить известные ошибочные варианты на правильные термины.
    public func apply(to text: String) -> String {
        var result = text
        for (pattern, term, keepEnding) in replacements {
            let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                var replacement = term
                if keepEnding, let ending = Range(match.range(at: 1), in: result) {
                    replacement += result[ending]
                }
                result.replaceSubrange(range, with: Self.matchingCase(replacement, of: result[range]))
            }
        }
        return result
    }

    /// Если термин со строчной, а исходное слово начиналось с заглавной (начало предложения) — сохраняем заглавную.
    static func matchingCase(_ term: String, of original: Substring) -> String {
        guard let first = term.first, first.isLowercase, original.first?.isUppercase == true else { return term }
        return first.uppercased() + term.dropFirst()
    }
}
