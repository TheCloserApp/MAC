import Foundation

// MARK: - Tiny test runner
//
// Intentionally avoids XCTest so tests can be compiled as a plain swiftc
// executable alongside the main sources, without pulling in an entire
// Xcode/SPM test bundle.

struct TestFailure: Error { let message: String; let file: String; let line: Int }

@MainActor
final class TestRunner {
    static var passed = 0
    static var failed: [(String, String, String, Int)] = []
    static var current = ""

    static func run(_ name: String, _ body: () throws -> Void) {
        current = name
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch let f as TestFailure {
            failed.append((name, f.message, f.file, f.line))
            print("  ✗ \(name)  — \(f.message)  @ \(f.file):\(f.line)")
        } catch {
            failed.append((name, "\(error)", #file, #line))
            print("  ✗ \(name)  — \(error)")
        }
    }
}

func assertEq<T: Equatable>(_ a: T, _ b: T, _ note: String = "", file: String = #file, line: Int = #line) throws {
    if a != b {
        throw TestFailure(message: "\(a) != \(b)  \(note)", file: file, line: line)
    }
}

func assertTrue(_ cond: Bool, _ note: String = "", file: String = #file, line: Int = #line) throws {
    if !cond { throw TestFailure(message: "expected true: \(note)", file: file, line: line) }
}

func assertFalse(_ cond: Bool, _ note: String = "", file: String = #file, line: Int = #line) throws {
    if cond { throw TestFailure(message: "expected false: \(note)", file: file, line: line) }
}

// Isolates tests that write to UserDefaults / disk so they don't clobber the
// app's real persistence.
@MainActor
func withSandboxedDefaults(_ body: () throws -> Void) rethrows {
    let suiteName = "MacOverlayTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let previous = UserDefaults.standard
    _ = previous
    try body()
    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - Tests

@MainActor
func testModels() throws {
    // ChatTurn defaults
    let t = ChatTurn(role: .user, content: "hello")
    try assertEq(t.role, .user)
    try assertEq(t.content, "hello")
    try assertTrue(t.inputTokens == nil)

    // ChatSession display title
    var s = ChatSession()
    try assertEq(s.displayTitle, "New session")
    s.turns.append(ChatTurn(role: .user, content: "Tell me about yourself for interview"))
    try assertTrue(s.displayTitle.hasPrefix("Tell me about yourself"))

    // Token totals
    var withTokens = ChatSession()
    withTokens.turns = [
        ChatTurn(role: .user, content: "q"),
        ChatTurn(role: .assistant, content: "a", inputTokens: 10, outputTokens: 20),
        ChatTurn(role: .user, content: "q2"),
        ChatTurn(role: .assistant, content: "a2", inputTokens: 5, outputTokens: 7)
    ]
    try assertEq(withTokens.totalInputTokens, 15)
    try assertEq(withTokens.totalOutputTokens, 27)
    try assertEq(withTokens.totalTokens, 42)

    // Summary pluralisation
    var one = ChatSession()
    one.turns.append(ChatTurn(role: .user, content: "q"))
    try assertEq(one.summary, "1 message")
    one.turns.append(ChatTurn(role: .user, content: "q2"))
    try assertEq(one.summary, "2 messages")
}

@MainActor
func testPromptPreset() throws {
    let p = PromptPreset(name: "Interview", content: "You are coach", linkedMode: .interview)
    try assertEq(p.name, "Interview")
    try assertEq(p.linkedMode, .interview)

    // Codable round-trip
    let data = try JSONEncoder().encode(p)
    let decoded = try JSONDecoder().decode(PromptPreset.self, from: data)
    try assertEq(decoded.id, p.id)
    try assertEq(decoded.content, p.content)
}

@MainActor
func testResumePreset() throws {
    let r = ResumePreset(name: "Backend", content: "Worked at X", tags: ["backend", "go"])
    try assertEq(r.tags.count, 2)
    try assertTrue(r.tags.contains("backend"))

    let data = try JSONEncoder().encode(r)
    let decoded = try JSONDecoder().decode(ResumePreset.self, from: data)
    try assertEq(decoded.name, "Backend")
}

@MainActor
func testWorkspace() throws {
    let w = Workspace(name: "Work", icon: "briefcase", colorHex: "#FF0000", isDefault: false)
    try assertEq(w.name, "Work")
    try assertEq(w.icon, "briefcase")
    try assertFalse(w.isDefault)

    let data = try JSONEncoder().encode(w)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    try assertEq(decoded.colorHex, "#FF0000")
}

@MainActor
func testJSONStoreRoundTrip() throws {
    let items = [
        PromptPreset(name: "A", content: "aa"),
        PromptPreset(name: "B", content: "bb")
    ]
    let filename = "test-\(UUID().uuidString).json"
    JSONStore.save(items, to: filename)
    JSONStore.flush()   // save is async — wait for the write to land
    let loaded = JSONStore.load([PromptPreset].self, from: filename)
    try assertTrue(loaded != nil, "expected loaded non-nil")
    try assertEq(loaded?.count ?? 0, 2)
    try assertEq(loaded?[0].name ?? "", "A")

    // Cleanup
    try? FileManager.default.removeItem(at: JSONStore.url(for: filename))
}

@MainActor
func testAIManagerModelRouting() throws {
    let ai = AIManager.shared
    try assertTrue(ai.isOpenAIModel("gpt-4o"))
    try assertTrue(ai.isOpenAIModel("gpt-4o-mini"))
    try assertTrue(ai.isOpenAIModel("o3-mini"))
    try assertFalse(ai.isOpenAIModel("claude-sonnet-4-6"))
    try assertFalse(ai.isOpenAIModel("claude-haiku-4-5-20251001"))
    try assertFalse(ai.isOpenAIModel("some-random-model"))
}

@MainActor
func testResumeScoreParser() throws {
    let raw = """
    SCORE: 82
    VERDICT: Strong match with minor tailoring
    MISSING_KEYWORDS: kubernetes, grafana, on-call
    STRENGTHS: backend, APIs, SQL
    """
    let s = ResumeScore(raw: raw)
    try assertEq(s.score, 82)
    try assertTrue(s.verdict.contains("Strong match"))
    try assertEq(s.missing.count, 3)
    try assertTrue(s.missing.contains("kubernetes"))
    try assertEq(s.strengths.count, 3)
    try assertEq(s.color, "green")
}

@MainActor
func testResumeScoreVerdictColors() throws {
    let high = ResumeScore(score: 90, verdict: "v", missing: [], strengths: [])
    try assertEq(high.color, "green")
    let mid  = ResumeScore(score: 65, verdict: "v", missing: [], strengths: [])
    try assertEq(mid.color, "yellow")
    let low  = ResumeScore(score: 30, verdict: "v", missing: [], strengths: [])
    try assertEq(low.color, "red")
    try assertTrue(low.recommendation.contains("Low match"))
}

@MainActor
func testSessionTitleAutoSetOnFirstTurn() throws {
    var s = ChatSession()
    try assertTrue(s.title.isEmpty)
    s.turns.append(ChatTurn(role: .user, content: "Walk me through a grokking algorithms question."))
    // Title itself is only set by SessionStore.appendUser; here we test
    // displayTitle's fallback path.
    try assertTrue(s.displayTitle.hasPrefix("Walk me through a grokking"))
}

@MainActor
func testSessionTurnOrderAfterAppend() throws {
    var s = ChatSession()
    s.turns.append(ChatTurn(role: .user, content: "q1"))
    s.turns.append(ChatTurn(role: .assistant, content: "a1"))
    s.turns.append(ChatTurn(role: .user, content: "q2"))
    s.turns.append(ChatTurn(role: .assistant, content: "a2"))
    try assertEq(s.turns.count, 4)
    try assertEq(s.turns[0].role, .user)
    try assertEq(s.turns[1].role, .assistant)
    try assertEq(s.turns[2].content, "q2")
    try assertEq(s.turns[3].content, "a2")
}

@MainActor
func testSessionModeSystemPromptNotEmpty() throws {
    for mode in SessionMode.allCases {
        try assertFalse(mode.systemPrompt.isEmpty, "\(mode) prompt empty")
        try assertFalse(mode.displayName.isEmpty, "\(mode) display name empty")
        try assertFalse(mode.icon.isEmpty, "\(mode) icon empty")
    }
}

@MainActor
func testSessionModeQuickActionsExist() throws {
    for mode in SessionMode.allCases {
        try assertTrue(mode.quickActions.count >= 1,
                       "\(mode) should have at least one quick action")
    }
}

@MainActor
func testAudioSourceLabels() throws {
    try assertEq(AudioSource.microphone.label, "Mic")
    try assertEq(AudioSource.systemAudio.label, "System")
    try assertEq(AudioSource.both.label, "Both")
    try assertEq(AudioSource.allCases.count, 3)
}

@MainActor
func testTurnIDsAreUnique() throws {
    let turns = (0..<50).map { _ in ChatTurn(role: .user, content: "x") }
    let ids = Set(turns.map(\.id))
    try assertEq(ids.count, turns.count)
}

@MainActor
func testNoteEntryRoundTrip() throws {
    let note = NoteEntry(timestamp: Date(), source: .ai, content: "hi", mode: .interview)
    let data = try JSONEncoder().encode(note)
    let decoded = try JSONDecoder().decode(NoteEntry.self, from: data)
    try assertEq(decoded.content, "hi")
    try assertTrue(decoded.source == NoteSource.ai)
    try assertTrue(decoded.mode == SessionMode.interview)
}

@MainActor
func testTranscriptFilterMeaningful() throws {
    // Real speech passes.
    try assertTrue(TranscriptFilter.isMeaningful("What is your biggest weakness?"))
    try assertTrue(TranscriptFilter.isMeaningful("ok tell me about react"))
    // Filler-only, annotations, and noise are rejected.
    try assertFalse(TranscriptFilter.isMeaningful(""))
    try assertFalse(TranscriptFilter.isMeaningful("   "))
    try assertFalse(TranscriptFilter.isMeaningful("um, uh… hmm."))
    try assertFalse(TranscriptFilter.isMeaningful("[noise]"))
    try assertFalse(TranscriptFilter.isMeaningful("(music) [BLANK_AUDIO]"))
    try assertFalse(TranscriptFilter.isMeaningful("a"))
    // Filler around real content still counts as content.
    try assertTrue(TranscriptFilter.isMeaningful("um so why Swift?"))
}

@MainActor
func testTranscriptFilterSeemsComplete() throws {
    // Terminal punctuation → complete.
    try assertTrue(TranscriptFilter.seemsComplete("Tell me about yourself."))
    try assertTrue(TranscriptFilter.seemsComplete("What is a closure in Swift?"))
    try assertTrue(TranscriptFilter.seemsComplete("That's impressive!"))
    // Trailing off / mid-thought → incomplete.
    try assertFalse(TranscriptFilter.seemsComplete(""))
    try assertFalse(TranscriptFilter.seemsComplete("So tell me about…"))
    try assertFalse(TranscriptFilter.seemsComplete("So, tell me about..."))
    try assertFalse(TranscriptFilter.seemsComplete("Walk me through your experience with"))
    try assertFalse(TranscriptFilter.seemsComplete("And then we need to,"))
    try assertFalse(TranscriptFilter.seemsComplete("What do you think about the"))
    try assertFalse(TranscriptFilter.seemsComplete("Can you explain how"))
    // Unpunctuated but neutral ending → treated as complete so engines
    // that don't punctuate don't stall every send.
    try assertTrue(TranscriptFilter.seemsComplete("Tell me about your last project"))
}

@MainActor
func testTranscriptFilterEchoesAnswer() throws {
    let answer = """
    I led the migration of our payment service to Kubernetes, cutting deploy
    times from 40 minutes to under 5 while keeping 99.9% uptime across the
    transition. The key was canary rollouts with automated rollback.
    """
    // User reading the answer aloud → echo, must be dropped.
    try assertTrue(TranscriptFilter.echoesAnswer(
        "I led the migration of our payment service to Kubernetes cutting deploy times",
        answer: answer))
    try assertTrue(TranscriptFilter.echoesAnswer(
        "the key was canary rollouts with automated rollback keeping uptime",
        answer: answer))
    // A real follow-up question brings new vocabulary → passes through.
    try assertFalse(TranscriptFilter.echoesAnswer(
        "Interesting — how did you handle stateful workloads and database failover during that?",
        answer: answer))
    try assertFalse(TranscriptFilter.echoesAnswer(
        "Tell me about a time you disagreed with your manager.",
        answer: answer))
    // Edge cases: empty answer or tiny segments never count as echo.
    try assertFalse(TranscriptFilter.echoesAnswer("anything at all here", answer: ""))
    try assertFalse(TranscriptFilter.echoesAnswer("the key was", answer: answer))
    // A "?"-terminated segment is a question, never a read-back — even
    // when it reuses the answer's vocabulary heavily (follow-ups quote
    // the answer all the time).
    try assertFalse(TranscriptFilter.echoesAnswer(
        "canary rollouts with automated rollback during the payment migration?",
        answer: answer))
}

@MainActor
func testTranscriptFilterNormalized() throws {
    // Punctuation / casing revisions normalize to the same form — the
    // signal the auto-send debounce uses to ignore cosmetic re-emits.
    try assertEq(TranscriptFilter.normalized("so tell me"),
                 TranscriptFilter.normalized("So, tell me"))
    try assertEq(TranscriptFilter.normalized("What is REST?"),
                 TranscriptFilter.normalized("what is rest"))
    // New words are a substantive change.
    try assertTrue(TranscriptFilter.normalized("so tell me")
                   != TranscriptFilter.normalized("so tell me about"))
    try assertEq(TranscriptFilter.normalized("  "), "")
}

@MainActor
func testChatTurnReplayText() throws {
    // No hidden context → replay is just the visible content.
    let plain = ChatTurn(role: .user, content: "hello")
    try assertEq(plain.replayText, "hello")

    // Hidden context (attachment blocks) is prepended for replay.
    let withCtx = ChatTurn(role: .user, content: "first question",
                           attachments: ["resume.pdf"],
                           hiddenContext: "[Attached resume.pdf]\n\nresume body")
    try assertEq(withCtx.replayText, "[Attached resume.pdf]\n\nresume body\n\nfirst question")

    // Attachment-only sends (empty visible text) replay the blocks alone.
    let ctxOnly = ChatTurn(role: .user, content: "", hiddenContext: "blocks")
    try assertEq(ctxOnly.replayText, "blocks")
}

@MainActor
func testChatTurnHiddenContextCodable() throws {
    let turn = ChatTurn(role: .user, content: "q",
                        attachments: ["jd.pdf"], hiddenContext: "ctx")
    let data = try JSONEncoder().encode(turn)
    let decoded = try JSONDecoder().decode(ChatTurn.self, from: data)
    try assertEq(decoded.hiddenContext ?? "", "ctx")

    // Legacy turns (no hiddenContext key) still decode.
    let legacy = #"{"id":"\#(UUID().uuidString)","role":"user","content":"old"}"#
    let migrated = try JSONDecoder().decode(ChatTurn.self, from: Data(legacy.utf8))
    try assertTrue(migrated.hiddenContext == nil)
    try assertEq(migrated.replayText, "old")
}

// MARK: - Entry point

@main
@MainActor
struct TestsMain {
    static func main() {
        print("Running MacOverlay tests…\n")

        TestRunner.run("models: turn / session / tokens", testModels)
        TestRunner.run("model: PromptPreset codable", testPromptPreset)
        TestRunner.run("model: ResumePreset codable", testResumePreset)
        TestRunner.run("model: Workspace codable", testWorkspace)
        TestRunner.run("JSONStore round-trip on disk", testJSONStoreRoundTrip)
        TestRunner.run("AIManager routes OpenAI models", testAIManagerModelRouting)
        TestRunner.run("ResumeScore parses raw format", testResumeScoreParser)
        TestRunner.run("ResumeScore verdict colors + copy", testResumeScoreVerdictColors)
        TestRunner.run("ChatSession displayTitle fallback", testSessionTitleAutoSetOnFirstTurn)
        TestRunner.run("ChatSession turn order preserved", testSessionTurnOrderAfterAppend)
        TestRunner.run("SessionMode has non-empty fields", testSessionModeSystemPromptNotEmpty)
        TestRunner.run("SessionMode has quick actions", testSessionModeQuickActionsExist)
        TestRunner.run("AudioSource labels + cases", testAudioSourceLabels)
        TestRunner.run("ChatTurn IDs unique", testTurnIDsAreUnique)
        TestRunner.run("NoteEntry codable round-trip", testNoteEntryRoundTrip)
        TestRunner.run("TranscriptFilter meaningful speech", testTranscriptFilterMeaningful)
        TestRunner.run("TranscriptFilter question completeness", testTranscriptFilterSeemsComplete)
        TestRunner.run("TranscriptFilter answer echo suppression", testTranscriptFilterEchoesAnswer)
        TestRunner.run("TranscriptFilter normalized change detection", testTranscriptFilterNormalized)
        TestRunner.run("ChatTurn replayText composition", testChatTurnReplayText)
        TestRunner.run("ChatTurn hiddenContext codable + migration", testChatTurnHiddenContextCodable)

        print("\n──────────────────────────────")
        print("  Passed: \(TestRunner.passed)")
        print("  Failed: \(TestRunner.failed.count)")
        if !TestRunner.failed.isEmpty {
            print("\nFailures:")
            for (name, msg, file, line) in TestRunner.failed {
                print("  · \(name)\n    \(msg)\n    \(file):\(line)")
            }
            exit(1)
        }
        print("──────────────────────────────")
        exit(0)
    }
}
