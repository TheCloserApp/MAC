import AppKit
import CryptoKit
import Foundation
import IOKit
import Observation

/// TheCloser Pro: the paid plan where we run the AI, so the user needs no
/// keys.
///
/// There's no account and no sign-in. The subscription is locked to this
/// Mac by an anonymous fingerprint (a hash of its hardware UUID), and the
/// server at thecloser.tech hands out a signed pass that lasts an hour.
/// The app renews the pass before it runs out. AI requests carry it to
/// `/api/chat`, which forwards them to OpenRouter with this subscription's
/// own capped key. The server code lives in the website repository, under
/// `api/`.
///
/// The pass is kept in UserDefaults next to the API keys, not the
/// Keychain: builds are ad-hoc signed, so each update would make macOS ask
/// to allow Keychain access again. It's only good for an hour, and only
/// together with this Mac's fingerprint.
@MainActor
@Observable
final class ProAccount {
    static let shared = ProAccount()

    nonisolated static let api = URL(string: "https://www.thecloser.tech/api/")!
    nonisolated static let chatURL = api.appending(path: "chat").absoluteString

    enum Plan: String, CaseIterable, Identifiable {
        case pro
        case proMax = "pro_max"

        var id: String { rawValue }
        var name: String { self == .pro ? "Pro" : "Pro Max" }
        var price: String { self == .pro ? "$19" : "$39" }
    }

    /// `/api/usage`: how much of this billing period's allowance is used.
    struct Usage: Decodable, Equatable {
        let plan: String
        let allowanceUSD: Double
        let usedUSD: Double
        let remainingUSD: Double
        let usedFraction: Double
        /// When the period ends, in Unix seconds. The allowance resets then,
        /// or the subscription ends if `renews` is false.
        let periodEnd: Double?
        let renews: Bool

        var percentUsed: Int { Int((min(max(usedFraction, 0), 1) * 100).rounded()) }
        var isUsedUp: Bool { remainingUSD <= 0.000_1 }
        var isRunningLow: Bool { usedFraction >= 0.8 }

        /// "Resets Oct 26", or "Ends Oct 26" after the user cancelled.
        var periodEndText: String? {
            guard let periodEnd else { return nil }
            let date = Date(timeIntervalSince1970: periodEnd)
            return "\(renews ? "Resets" : "Ends") \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    enum RenewResult { case active, notSubscribed, settingUp, failed }

    struct Credentials: Sendable {
        let pass: String
        let device: String
    }

    /// The current plan, or nil when this Mac has no subscription.
    private(set) var plan: Plan?
    /// OpenRouter ids of the models the plan includes.
    private(set) var models: [String] = []
    private(set) var usage: Usage?
    /// True from opening Stripe Checkout until the payment shows up here.
    private(set) var isWaitingForCheckout = false
    /// Last thing that went wrong, worded for the user. Cleared on success.
    var problem: String?

    var isActive: Bool { plan != nil }

    /// Told when the plan starts, changes or ends.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var pass: String?
    @ObservationIgnored private var expiresAt = Date.distantPast
    @ObservationIgnored private var renewing: Task<RenewResult, Never>?
    @ObservationIgnored private var renewalTimer: Task<Void, Never>?
    @ObservationIgnored private var checkoutPolling: Task<Void, Never>?
    @ObservationIgnored private var usageRefresh: Task<Void, Never>?

    private enum Key {
        static let pass = "pro.pass"
        static let expiresAt = "pro.expiresAt"
        static let plan = "pro.plan"
        static let models = "pro.models"
        static let checkoutPending = "pro.checkoutPending"
    }

    private init() {
        guard FeatureFlags.proSubscriptionsEnabled else { return }
        let defaults = UserDefaults.standard
        pass = defaults.string(forKey: Key.pass)
        expiresAt = Date(timeIntervalSince1970: defaults.double(forKey: Key.expiresAt))
        plan = defaults.string(forKey: Key.plan).flatMap(Plan.init(rawValue:))
        models = defaults.stringArray(forKey: Key.models) ?? []
        if pass == nil { plan = nil }
        ModelVisibility.shared.allowed = allowedModelIDs
    }

    /// At launch: renew a stored pass, or pick up a checkout that finished
    /// after the app quit.
    func start() {
        guard FeatureFlags.proSubscriptionsEnabled else { return }
        if isActive || UserDefaults.standard.bool(forKey: Key.checkoutPending) {
            Task { await renew() }
        }
    }

    // MARK: - Device

    /// This Mac's anonymous fingerprint, or nil if the hardware UUID can't
    /// be read. The server only ever sees this hash.
    nonisolated static let device: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return uuid.flatMap(fingerprint(platformUUID:))
    }()

    /// SHA-256 of "thecloser-device-v1:" + the hardware UUID, as 64
    /// lowercase hex characters.
    nonisolated static func fingerprint(platformUUID: String) -> String? {
        guard !platformUUID.isEmpty else { return nil }
        return SHA256.hash(data: Data("thecloser-device-v1:\(platformUUID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Subscribing

    /// Opens Stripe Checkout in the browser, then waits for the payment to
    /// show up (up to 15 minutes, or until `stopWaitingForCheckout`).
    func subscribe(to plan: Plan) async {
        guard let device = Self.device else {
            problem = "This Mac's hardware ID couldn't be read, so Pro can't be set up on it."
            return
        }
        problem = nil
        do {
            let (status, data) = try await call("POST", "checkout", body: ["device": device, "plan": plan.rawValue])
            switch status {
            case 200:
                let url = try JSONDecoder().decode(LinkResponse.self, from: data).url
                UserDefaults.standard.set(true, forKey: Key.checkoutPending)
                NSWorkspace.shared.open(url)
                waitForCheckout()
            case 409:
                // Already subscribed on this Mac: this just picks it up.
                if await renew() != .active { problem = "This Mac already has a subscription, but it couldn't be loaded. Try again in a minute." }
            default:
                problem = "Checkout couldn't be opened. Try again in a moment."
            }
        } catch {
            problem = "Couldn't reach TheCloser. Check your connection and try again."
        }
    }

    func stopWaitingForCheckout() {
        checkoutPolling?.cancel()
        checkoutPolling = nil
        isWaitingForCheckout = false
    }

    /// "Already subscribed on this Mac?": looks the subscription up again.
    func restore() async {
        problem = nil
        switch await renew() {
        case .active:        break
        case .notSubscribed: problem = "No subscription found for this Mac."
        case .settingUp:     problem = "Your subscription is still being set up. Try again in a minute."
        case .failed:        problem = "Couldn't reach TheCloser. Check your connection and try again."
        }
    }

    private func waitForCheckout() {
        checkoutPolling?.cancel()
        isWaitingForCheckout = true
        checkoutPolling = Task { [weak self] in
            // Stripe's search can take about a minute to see a new
            // subscription, so a "not found" here isn't final.
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if await self.renew() == .active { break }
            }
            self?.isWaitingForCheckout = false
            self?.checkoutPolling = nil
        }
    }

    // MARK: - The pass

    /// Gets a fresh pass. Concurrent callers share one request.
    @discardableResult
    func renew() async -> RenewResult {
        if let renewing { return await renewing.value }
        let task = Task { await performRenew() }
        renewing = task
        let result = await task.value
        renewing = nil
        return result
    }

    private func performRenew() async -> RenewResult {
        guard let device = Self.device else { return .failed }
        var body: [String: Any] = ["device": device]
        if let pass { body["pass"] = pass }
        do {
            let (status, data) = try await call("POST", "pass", body: body)
            switch status {
            case 200:
                let response = try JSONDecoder().decode(PassResponse.self, from: data)
                guard let plan = Plan(rawValue: response.plan) else { return .failed }
                activate(pass: response.pass, expiresAt: Date(timeIntervalSince1970: response.expiresAt),
                         plan: plan, models: response.models)
                return .active
            case 402:
                UserDefaults.standard.removeObject(forKey: Key.checkoutPending)
                deactivate()
                return .notSubscribed
            case 409:
                return .settingUp
            default:
                scheduleRenewal(after: 60)
                return .failed
            }
        } catch {
            scheduleRenewal(after: 60)
            return .failed
        }
    }

    private func activate(pass: String, expiresAt: Date, plan: Plan, models: [String]) {
        let changed = self.plan != plan || self.models != models
        self.pass = pass
        self.expiresAt = expiresAt
        self.plan = plan
        self.models = models
        let defaults = UserDefaults.standard
        defaults.set(pass, forKey: Key.pass)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: Key.expiresAt)
        defaults.set(plan.rawValue, forKey: Key.plan)
        defaults.set(models, forKey: Key.models)
        defaults.removeObject(forKey: Key.checkoutPending)
        problem = nil
        stopWaitingForCheckout()
        // Renew five minutes early. A Mac that sleeps through it gets a
        // refused request instead, which renews and retries.
        scheduleRenewal(after: max(60, expiresAt.timeIntervalSinceNow - 300))
        if changed {
            ModelVisibility.shared.allowed = allowedModelIDs
            onChange?()
        }
        if changed || usage == nil { Task { await refreshUsage() } }
    }

    private func deactivate() {
        guard isActive || pass != nil else { return }
        pass = nil
        plan = nil
        models = []
        usage = nil
        renewalTimer?.cancel()
        for key in [Key.pass, Key.expiresAt, Key.plan, Key.models] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        ModelVisibility.shared.allowed = nil
        onChange?()
    }

    private func scheduleRenewal(after seconds: TimeInterval) {
        guard isActive else { return }
        renewalTimer?.cancel()
        renewalTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.renew()
        }
    }

    /// Catalogue ids ("openrouter/…") the plan allows, or nil for no limit.
    private var allowedModelIDs: Set<String>? {
        isActive ? Set(models.map { AIManager.openRouterPrefix + $0 }) : nil
    }

    // MARK: - Used by AIManager

    /// The pass for an AI request, renewed first if it's about to run out.
    /// Nil once the subscription has ended.
    func credentials() async -> Credentials? {
        guard isActive, let device = Self.device else { return nil }
        if expiresAt.timeIntervalSinceNow < 60 { await renew() }
        guard isActive, let pass else { return nil }
        return Credentials(pass: pass, device: device)
    }

    /// Why the server refused a request, in words the user can act on.
    func explainRefusal(status: Int, body: String) async -> Error {
        if body.contains("model_not_in_plan") {
            return AIError.pro("This model isn't included in \(plan?.name ?? "your plan"). Pick another one from the model menu.")
        }
        await refreshUsage()
        if let usage, usage.isUsedUp { return AIError.pro(usedUpMessage(usage)) }
        return AIError.apiError(status, body)
    }

    func usedUpMessage(_ usage: Usage) -> String {
        var message = "You've used all of this month's \(plan?.name ?? "Pro") allowance."
        if let periodEnd = usage.periodEnd, usage.renews {
            message += " It resets on \(Date(timeIntervalSince1970: periodEnd).formatted(.dateTime.month(.wide).day()))."
        }
        if plan == .pro { message += " Pro Max has 2.5× more: Settings → AI → Manage subscription." }
        return message
    }

    /// After an answer, check usage again so the setup screen can warn
    /// before it runs out. OpenRouter's figures lag about a minute, so this
    /// waits, and runs at most once per wait.
    func noteRequestFinished() {
        guard usageRefresh == nil else { return }
        usageRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(75))
            await self?.refreshUsage()
            self?.usageRefresh = nil
        }
    }

    // MARK: - Usage and billing

    func refreshUsage() async {
        guard isActive, let pass else { return }
        do {
            var (status, data) = try await call("GET", "usage", pass: pass)
            if status == 401 {
                guard await renew() == .active, let fresh = self.pass else { return }
                (status, data) = try await call("GET", "usage", pass: fresh)
            }
            switch status {
            case 200: usage = try JSONDecoder().decode(Usage.self, from: data)
            case 402: await renew()
            default:  break
            }
        } catch {
            // Keep showing the last figures.
        }
    }

    /// Stripe's billing portal: change plan, update the card, or cancel.
    func openManageSubscription() async {
        problem = nil
        if expiresAt.timeIntervalSinceNow < 60 { await renew() }
        guard isActive, let pass else { return }
        do {
            let (status, data) = try await call("POST", "portal", pass: pass)
            guard status == 200 else {
                problem = "Subscription settings couldn't be opened. Try again in a moment."
                return
            }
            NSWorkspace.shared.open(try JSONDecoder().decode(LinkResponse.self, from: data).url)
        } catch {
            problem = "Couldn't reach TheCloser. Check your connection and try again."
        }
    }

    #if PREVIEW
    /// A plan and usage without a server, to render screens off-screen.
    /// Only in builds compiled with `-D PREVIEW`.
    func preview(plan: Plan?, usage: Usage?, waitingForCheckout: Bool = false, problem: String? = nil) {
        self.plan = plan
        models = plan == nil ? [] : ["anthropic/claude-sonnet-5", "anthropic/claude-haiku-4.5", "openai/gpt-5.4-mini"]
        self.usage = usage
        isWaitingForCheckout = waitingForCheckout
        self.problem = problem
        ModelVisibility.shared.allowed = allowedModelIDs
        onChange?()
    }
    #endif

    // MARK: - HTTP

    private struct PassResponse: Decodable {
        let pass: String
        let expiresAt: Double
        let plan: String
        let models: [String]
    }

    private struct LinkResponse: Decodable {
        let url: URL
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil,
                      pass: String? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: Self.api.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let pass { request.setValue("Bearer \(pass)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
