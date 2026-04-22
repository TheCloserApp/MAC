import Foundation

/// Result of scoring a resume against a JD. Parsed from the strict plain-text
/// format the AI is asked to return.
struct ResumeScore: Codable, Hashable {
    let score:     Int
    let verdict:   String
    let missing:   [String]
    let strengths: [String]

    init(raw: String) {
        var s = 0; var v = ""; var m: [String] = []; var st: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SCORE:") {
                s = Int(l.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if l.hasPrefix("VERDICT:") {
                v = String(l.dropFirst(8).trimmingCharacters(in: .whitespaces))
            } else if l.hasPrefix("MISSING_KEYWORDS:") {
                m = l.dropFirst(17).components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if l.hasPrefix("STRENGTHS:") {
                st = l.dropFirst(10).components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        score = s; verdict = v; missing = m; strengths = st
    }

    init(score: Int, verdict: String, missing: [String], strengths: [String]) {
        self.score = score; self.verdict = verdict
        self.missing = missing; self.strengths = strengths
    }

    var color: String {
        score >= 80 ? "green" : score >= 60 ? "yellow" : "red"
    }
    var recommendation: String {
        score >= 80 ? "Good match — safe to apply as-is"
                    : score >= 60 ? "Decent match — minor tweaks recommended"
                    : "Low match — use Ctrl+Opt+R to tailor your resume"
    }
}
