import AuthenticationServices
import Foundation
import M2CCheckoutCore
import UIKit

@MainActor
public final class M2CCheckoutClient {
    private let config: M2CCheckoutConfig
    private let transport: any CheckoutTransporting
    private let browser: any BrowserPresenting
    private let resumeStore: any ResumeStoring
    private let clock: any CheckoutClock
    private let sleeper: any CheckoutSleeper
    private var continuations: [UUID: AsyncStream<CheckoutState>.Continuation] = [:]

    public private(set) var state: CheckoutState = .idle

    public var states: AsyncStream<CheckoutState> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(state)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public init(config: M2CCheckoutConfig) throws {
        try Self.validate(config)
        self.config = config
        self.transport = CheckoutTransport()
        self.browser = SystemBrowserPresenter()
        self.resumeStore = UserDefaultsResumeStore()
        self.clock = SystemCheckoutClock()
        self.sleeper = TaskCheckoutSleeper()
    }

    init(
        config: M2CCheckoutConfig,
        transport: any CheckoutTransporting,
        browser: any BrowserPresenting,
        resumeStore: any ResumeStoring,
        clock: any CheckoutClock,
        sleeper: any CheckoutSleeper
    ) throws {
        try Self.validate(config)
        self.config = config
        self.transport = transport
        self.browser = browser
        self.resumeStore = resumeStore
        self.clock = clock
        self.sleeper = sleeper
    }

    public func start(
        request: AuctionRequest,
        presentationContext: M2CCheckoutPresentationContextProviding,
        options: CheckoutStartOptions = .init()
    ) async throws -> CheckoutResult {
        try rejectPendingRecovery()
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        transition(.creating)
        let started = clock.now()
        let fallbackEnabled = config.fallbackHandler != nil && options.fallbackMode != .disabled

        guard let key = config.publishableKey else {
            transition(.error)
            throw M2CCheckoutError(
                .invalidRequest,
                "publishableKey is required for client-initiated checkout"
            )
        }
        let session: CheckoutSession
        let returnURLs = ReturnURLs(
            success: request.successURL ?? config.returnURLs.success,
            cancel: request.cancelURL ?? config.returnURLs.cancel
        )
        do {
            try Self.validate(returnURLs, browserMode: config.browserMode)
            session = try await transport.createAuction(
                request: request,
                returnURLs: returnURLs,
                publishableKey: key,
                timeout: fallbackEnabled ? config.fallbackDeadline : 30
            )
        } catch let error as M2CCheckoutError {
            if Task.isCancelled { throw CancellationError() }
            if fallbackEnabled,
               let reason = fallbackReason(for: error, elapsed: clock.now().timeIntervalSince(started)) {
                return try await invokeFallback(
                    reason: reason,
                    error: error,
                    requestID: nil,
                    request: request,
                    options: options,
                    started: started
                )
            }
            transition(.error)
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            transition(.error)
            throw M2CCheckoutError(.unknown, error.localizedDescription)
        }
        try Task.checkCancellation()
        do {
            return try await runSession(
                session,
                mode: .client,
                presentationContext: presentationContext,
                options: options,
                request: request,
                returnURLs: returnURLs,
                started: started
            )
        } catch let error as M2CCheckoutError {
            transition(.error)
            throw error
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    public func start(
        session: CheckoutSession,
        presentationContext: M2CCheckoutPresentationContextProviding,
        options: CheckoutStartOptions = .init()
    ) async throws -> CheckoutResult {
        try rejectPendingRecovery()
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let started = clock.now()
        do {
            return try await runSession(
                session,
                mode: .backend,
                presentationContext: presentationContext,
                options: options,
                request: nil,
                returnURLs: config.returnURLs,
                started: started
            )
        } catch let error as M2CCheckoutError {
            transition(.error)
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            transition(.error)
            throw M2CCheckoutError(.unknown, error.localizedDescription)
        }
    }

    public func checkStatus(requestID: String) async throws -> ClientStatus {
        guard !requestID.isEmpty else {
            throw M2CCheckoutError(.invalidRequest, "requestID is required")
        }
        return try await readConfiguredStatus(requestID: requestID, checkoutStarted: clock.now())
    }

    public func tryResume() async throws -> CheckoutResult? {
        try ProcessCoordinator.shared.begin()
        defer { ProcessCoordinator.shared.finish() }
        let bufferedURL = ProcessCoordinator.shared.takeBufferedURL()
        let persistedRecord = resumeStore.load()
        guard let record = persistedRecord ?? recoveryRecord(from: bufferedURL) else {
            return nil
        }
        if persistedRecord == nil {
            try resumeStore.save(record)
        }
        do {
            if record.sourceKind == .callback {
                guard case .callback = config.statusSource else {
                    resumeStore.clear()
                    throw M2CCheckoutError(
                        .invalidRequest,
                        "resume requires the callback status source to be configured again"
                    )
                }
            }
            transition(.polling)
            let returnURLs = try restoredReturnURLs(for: record)
            if let bufferedURL {
                let classification = ReturnClassifier.classify(
                    returnURL: bufferedURL,
                    successURL: returnURLs.success,
                    cancelURL: returnURLs.cancel,
                    expectedRequestID: record.requestID
                )
                if classification.verdict == .cancel {
                    return settle(.canceled, requestID: record.requestID)
                }
            }
            let resumedAt = clock.now()
            let status = try await pollStatus(
                requestID: record.requestID,
                checkoutStarted: resumedAt,
                source: resumeStatusSource(record)
            )
            return settle(status, requestID: record.requestID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !isRetryable(error) { resumeStore.clear() }
            transition(.error)
            throw error
        }
    }

    private func recoveryRecord(from bufferedURL: URL?) -> ResumeRecord? {
        guard
            let bufferedURL,
            let requestID = URLComponents(
                url: bufferedURL,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "request_id" })?.value,
            !requestID.isEmpty
        else {
            return nil
        }
        let classification = ReturnClassifier.classify(
            returnURL: bufferedURL,
            successURL: config.returnURLs.success,
            cancelURL: config.returnURLs.cancel,
            expectedRequestID: requestID
        )
        guard classification.error == nil, classification.verdict != .unknown else {
            return nil
        }
        return ResumeRecord(
            requestID: requestID,
            integrationMode: .backend,
            sourceKind: sourceKind,
            statusURLTemplate: statusTemplate,
            successReturnURL: config.returnURLs.success.absoluteString,
            cancelReturnURL: config.returnURLs.cancel.absoluteString
        )
    }

    private func resumeStatusSource(_ record: ResumeRecord) throws -> StatusSource {
        switch record.sourceKind {
        case .m2c:
            guard config.publishableKey != nil else {
                throw M2CCheckoutError(.invalidRequest, "M2C resume requires a publishable key")
            }
            return .m2c
        case .url:
            guard let template = record.statusURLTemplate else {
                throw M2CCheckoutError(
                    .invalidRequest,
                    "recovery record omitted its status URL template"
                )
            }
            try CheckoutValidation.validateStatusTemplate(template)
            return .url(template: template)
        case .callback:
            guard case .callback(let callback) = config.statusSource else {
                throw M2CCheckoutError(
                    .invalidRequest,
                    "resume requires the callback status source to be configured again"
                )
            }
            return .callback(callback)
        }
    }

    @discardableResult
    public static func handleOpenURL(_ url: URL, returnURLs: ReturnURLs) -> Bool {
        let requestID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "request_id" })?
            .value ?? ""
        let classification = ReturnClassifier.classify(
            returnURL: url,
            successURL: returnURLs.success,
            cancelURL: returnURLs.cancel,
            expectedRequestID: requestID
        )
        guard classification.verdict != .unknown else { return false }
        return ProcessCoordinator.shared.ingest(url)
    }

    @discardableResult
    public static func handleUserActivity(
        _ activity: NSUserActivity,
        returnURLs: ReturnURLs
    ) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else { return false }
        return handleOpenURL(url, returnURLs: returnURLs)
    }

    public static func notifyDidEnterBackground() {
        ProcessCoordinator.shared.didEnterBackground()
    }

    public static func notifyDidBecomeActive() {
        ProcessCoordinator.shared.didBecomeActive()
    }

    private func runSession(
        _ session: CheckoutSession,
        mode: ResumeRecord.IntegrationMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        options: CheckoutStartOptions,
        request: AuctionRequest?,
        returnURLs: ReturnURLs,
        started: Date
    ) async throws -> CheckoutResult {
        guard !session.requestID.isEmpty else {
            throw M2CCheckoutError(.invalidRequest, "requestID is required")
        }
        try CheckoutValidation.validateCheckoutURL(session.checkoutURL)
        if let ttl = session.ttl {
            guard ttl.isFinite, ttl > 0 else {
                throw M2CCheckoutError(.checkoutExpired, "checkout session has expired")
            }
            if clock.now().timeIntervalSince(started) >= ttl {
                throw M2CCheckoutError(.checkoutExpired, "checkout session expired before launch")
            }
        }

        transition(.ready)
        let record = ResumeRecord(
            requestID: session.requestID,
            integrationMode: mode,
            sourceKind: sourceKind,
            statusURLTemplate: statusTemplate,
            successReturnURL: returnURLs.success.absoluteString,
            cancelReturnURL: returnURLs.cancel.absoluteString
        )
        let fallbackEnabled = config.fallbackHandler != nil && options.fallbackMode != .disabled
        try Task.checkCancellation()
        if !fallbackEnabled { try resumeStore.save(record) }

        transition(.launching)
        var exposed = false
        ProcessCoordinator.shared.bindReturn(
            requestID: session.requestID,
            returnURLs: returnURLs
        )
        ProcessCoordinator.shared.discardBufferedURLs()
        let outcome: BrowserOutcome
        do {
            try Task.checkCancellation()
            outcome = try await browser.open(
                checkoutURL: session.checkoutURL,
                callbackURL: returnURLs.success,
                mode: config.browserMode,
                presentationContext: presentationContext
            ) { [resumeStore] in
                exposed = true
                try? resumeStore.save(record)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if !exposed { resumeStore.clear() }
            throw CancellationError()
        } catch let error as M2CCheckoutError {
            if !exposed { resumeStore.clear() }
            if Task.isCancelled { throw CancellationError() }
            if !exposed, fallbackEnabled {
                return try await invokeFallback(
                    reason: .launchFailed,
                    error: error,
                    requestID: session.requestID,
                    request: request,
                    options: options,
                    started: started
                )
            }
            throw error
        }

        transition(.awaitingReturn)
        switch outcome {
        case .returned(let url):
            transition(.returned)
            let classification = ReturnClassifier.classify(
                returnURL: url,
                successURL: returnURLs.success,
                cancelURL: returnURLs.cancel,
                expectedRequestID: session.requestID
            )
            if classification.error == "request_id_mismatch" {
                return try await reconcileAmbiguous(
                    requestID: session.requestID,
                    checkoutStarted: started
                )
            }
            if classification.verdict == .cancel {
                return settle(.canceled, requestID: session.requestID)
            }
            guard classification.verdict == .success else {
                throw M2CCheckoutError(.invalidRequest, "return URL did not match configured URLs")
            }
            transition(.polling)
            return settle(
                try await pollStatus(requestID: session.requestID, checkoutStarted: started),
                requestID: session.requestID
            )
        case .dismissed:
            var status: ClientStatus
            do {
                status = try await readStatusOnce(
                    requestID: session.requestID,
                    checkoutStarted: started,
                    forceBackstop: true
                )
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                guard isRetryable(error) else { throw error }
                status = .processing
            }
            return settle(
                status == .processing ? .canceled : status,
                requestID: session.requestID
            )
        case .ambiguous:
            return try await reconcileAmbiguous(
                requestID: session.requestID,
                checkoutStarted: started
            )
        }
    }

    private func reconcileAmbiguous(
        requestID: String,
        checkoutStarted: Date
    ) async throws -> CheckoutResult {
        transition(.polling)
        let status = try await pollStatus(
            requestID: requestID,
            checkoutStarted: checkoutStarted,
            short: true
        )
        return settle(status, requestID: requestID)
    }

    private func pollStatus(
        requestID: String,
        checkoutStarted: Date,
        source: StatusSource? = nil,
        short: Bool = false
    ) async throws -> ClientStatus {
        let source = source ?? config.statusSource
        let window = short ? min(3, config.poll.timeout) : config.poll.timeout
        let deadline = clock.now().addingTimeInterval(window)
        let reserve = short && canUseBackstop(source) ? window / 2 : 0
        let primaryDeadline = deadline.addingTimeInterval(-reserve)
        let poller = StatusPoller(
            policy: PollPolicy(
                timeout: window - reserve,
                delays: short ? [0, 0.25, 0.5] : config.poll.delays
            ),
            clock: clock,
            sleeper: sleeper
        )
        let primary = try await poller.pollWithBudget { budget in
            let readDeadline = short ? primaryDeadline : self.clock.now().addingTimeInterval(budget)
            return try await self.readStatus(
                requestID: requestID,
                source: source,
                checkoutStarted: checkoutStarted,
                deadline: readDeadline,
                allowBackstop: !short
            )
        }
        try Task.checkCancellation()
        guard primary == .processing, reserve > 0,
              let key = config.publishableKey else { return primary }
        // The short return window reserves one last read even before the normal threshold.
        return try await readM2CBackstop(
            requestID: requestID,
            publishableKey: key,
            timeout: deadline.timeIntervalSince(clock.now())
        )
    }

    private func readConfiguredStatus(
        requestID: String,
        checkoutStarted: Date,
        forceBackstop: Bool = false
    ) async throws -> ClientStatus {
        try await readStatus(
            requestID: requestID,
            source: config.statusSource,
            checkoutStarted: checkoutStarted,
            deadline: clock.now().addingTimeInterval(30),
            forceBackstop: forceBackstop
        )
    }

    private func readPrimaryStatus(requestID: String, source: StatusSource) async throws -> ClientStatus {
        switch source {
        case .m2c:
            guard let key = config.publishableKey else {
                throw M2CCheckoutError(.invalidRequest, "M2C status requires a publishable key")
            }
            return try await transport.readM2CStatus(requestID: requestID, publishableKey: key)
        case .url(let template):
            return try await transport.readURLStatus(template: template, requestID: requestID)
        case .callback(let callback):
            return try await readCallback(callback, requestID: requestID)
        case .subscribe:
            throw M2CCheckoutError(.invalidRequest, "subscribe status source is reserved for a future release")
        }
    }

    private func canUseBackstop(_ source: StatusSource) -> Bool {
        guard config.statusBackstop.enabled, config.publishableKey != nil else { return false }
        switch source {
        case .url, .callback: return true
        default: return false
        }
    }

    private func readStatus(
        requestID: String,
        source: StatusSource,
        checkoutStarted: Date,
        deadline: Date,
        forceBackstop: Bool = false,
        allowBackstop: Bool = true
    ) async throws -> ClientStatus {
        try await resolveStatus(
            requestID: requestID,
            source: source,
            checkoutStarted: checkoutStarted,
            deadline: deadline,
            forceBackstop: forceBackstop,
            allowBackstop: allowBackstop
        ) { try await self.readPrimaryStatus(requestID: requestID, source: source) }
    }

    private func resolveStatus(
        requestID: String,
        source: StatusSource,
        checkoutStarted: Date,
        deadline: Date,
        forceBackstop: Bool,
        allowBackstop: Bool,
        primaryRead: @escaping @Sendable () async throws -> ClientStatus
    ) async throws -> ClientStatus {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSince(clock.now())
        guard remaining > 0 else { return .processing }
        let useBackstop = allowBackstop && canUseBackstop(source)
        let untilThreshold = config.statusBackstop.threshold - clock.now().timeIntervalSince(checkoutStarted)
        let primaryBudget = useBackstop
            ? (forceBackstop || untilThreshold <= 0 ? remaining / 2 : min(remaining, untilThreshold))
            : remaining
        var primaryError: Error?
        do {
            let primary = try await StatusPoller(policy: config.poll, clock: clock, sleeper: sleeper).readOnce(
                timeout: primaryBudget,
                read: primaryRead
            )
            try Task.checkCancellation()
            if primary != .processing { return primary }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            guard isRetryable(error) else { throw error }
            primaryError = error
        }
        try Task.checkCancellation()
        if useBackstop, let key = config.publishableKey,
           forceBackstop || clock.now().timeIntervalSince(checkoutStarted) >= config.statusBackstop.threshold {
            let backstop = try await readM2CBackstop(
                requestID: requestID,
                publishableKey: key,
                timeout: deadline.timeIntervalSince(clock.now())
            )
            if backstop != .processing { return backstop }
        }
        if let primaryError { throw primaryError }
        return .processing
    }

    private func readM2CBackstop(
        requestID: String,
        publishableKey: String,
        timeout: TimeInterval
    ) async throws -> ClientStatus {
        try Task.checkCancellation()
        guard timeout > 0 else { return .processing }
        do {
            let status = try await StatusPoller(policy: config.poll, clock: clock, sleeper: sleeper).readOnce(timeout: timeout) {
                try await self.transport.readM2CStatus(
                    requestID: requestID,
                    publishableKey: publishableKey
                )
            }
            try Task.checkCancellation()
            return status
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .processing
        }
    }

    private func readCallback(
        _ callback: @escaping @Sendable (String) async throws -> ClientStatus,
        requestID: String
    ) async throws -> ClientStatus {
        do {
            return try await callback(requestID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as M2CCheckoutError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw M2CCheckoutError(.serviceUnavailable, "status callback failed")
        }
    }

    private func readStatusOnce(
        requestID: String,
        checkoutStarted: Date,
        forceBackstop: Bool = false
    ) async throws -> ClientStatus {
        let timeout = min(config.poll.timeout, 3)
        return try await readStatus(
            requestID: requestID,
            source: config.statusSource,
            checkoutStarted: checkoutStarted,
            deadline: clock.now().addingTimeInterval(timeout),
            forceBackstop: forceBackstop
        )
    }

    private var sourceKind: ResumeRecord.SourceKind {
        switch config.statusSource {
        case .m2c: return .m2c
        case .url: return .url
        case .callback: return .callback
        case .subscribe: return .callback
        }
    }

    private var statusTemplate: String? {
        if case .url(let template) = config.statusSource { return template }
        return nil
    }

    private func restoredReturnURLs(for record: ResumeRecord) throws -> ReturnURLs {
        guard
            let success = URL(string: record.successReturnURL),
            let cancel = URL(string: record.cancelReturnURL)
        else {
            throw M2CCheckoutError(.invalidRequest, "recovery record return URLs were invalid")
        }
        let returnURLs = ReturnURLs(success: success, cancel: cancel)
        try Self.validate(returnURLs, browserMode: config.browserMode)
        return returnURLs
    }

    private func rejectPendingRecovery() throws {
        if resumeStore.load() != nil {
            throw M2CCheckoutError(
                .invalidRequest,
                "checkout recovery is pending; call tryResume() before starting another checkout"
            )
        }
    }

    private func settle(_ status: ClientStatus, requestID: String) -> CheckoutResult {
        switch status {
        case .completed:
            transition(.completed)
            resumeStore.clear()
            return .completed(requestID: requestID)
        case .failed:
            transition(.failed)
            resumeStore.clear()
            return .failed(requestID: requestID)
        case .canceled:
            transition(.canceled)
            resumeStore.clear()
            return .canceled(requestID: requestID)
        case .processing:
            transition(.pendingTimeout)
            resumeStore.clear()
            return .pendingTimeout(requestID: requestID)
        }
    }

    private func invokeFallback(
        reason: FallbackReason,
        error originalError: M2CCheckoutError,
        requestID: String?,
        request: AuctionRequest?,
        options: CheckoutStartOptions,
        started: Date
    ) async throws -> CheckoutResult {
        try Task.checkCancellation()
        guard let handler = config.fallbackHandler else { throw originalError }
        let attemptID = UUID().uuidString
        let context = FallbackContext(
            attemptID: attemptID,
            reason: reason,
            originalError: originalError,
            requestID: requestID,
            fallbackProductID: options.fallbackProductID,
            latencyMilliseconds: Int64(clock.now().timeIntervalSince(started) * 1_000),
            transactionValue: request?.transactionValue,
            currency: request?.currency,
            description: request?.description,
            reference: request?.reference
        )
        let decision: FallbackDecision
        do {
            decision = try await handler(reason, context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            transition(.error)
            throw originalError.withFallbackStatus(.handlerOutcomeUnknown)
        }
        if decision == .accepted {
            transition(.fallbackStarted)
            resumeStore.clear()
            return .fallbackStarted(attemptID: attemptID, requestID: requestID, reason: reason)
        } else {
            transition(.error)
            throw originalError.withFallbackStatus(.declined)
        }
    }

    private func fallbackReason(for error: M2CCheckoutError, elapsed: TimeInterval) -> FallbackReason? {
        switch error.code {
        case .noVendorsAvailable:
            return .noBids
        case .network where elapsed >= config.fallbackDeadline:
            return .timeout
        case .network, .rateLimited, .serviceUnavailable, .unknown:
            return .apiError
        default:
            return nil
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? M2CCheckoutError else { return false }
        return error.code == .network || error.code == .rateLimited || error.code == .serviceUnavailable
    }

    private func transition(_ next: CheckoutState) {
        state = next
        for continuation in continuations.values { continuation.yield(next) }
    }

    private static func validate(_ config: M2CCheckoutConfig) throws {
        try validate(config.returnURLs, browserMode: config.browserMode)
        if let key = config.publishableKey { try CheckoutValidation.validatePublishableKey(key) }
        try config.poll.validate()
        switch config.statusSource {
        case .m2c:
            try CheckoutValidation.validatePublishableKey(config.publishableKey)
        case .url(let template):
            try CheckoutValidation.validateStatusTemplate(template)
        case .callback:
            break
        case .subscribe:
            throw M2CCheckoutError(
                .invalidRequest,
                "subscribe status source is reserved for a future release"
            )
        }
        if config.statusBackstop.enabled {
            try CheckoutValidation.validatePublishableKey(config.publishableKey)
            if case .m2c = config.statusSource {
                throw M2CCheckoutError(
                    .invalidRequest,
                    "M2C status backstop applies only to URL and callback sources"
                )
            }
        }
        if config.fallbackHandler != nil,
           !(8...30).contains(config.fallbackDeadline) {
            throw M2CCheckoutError(
                .invalidRequest,
                "fallbackDeadline must be between 8 and 30 seconds"
            )
        }
    }

    private static func validate(_ returnURLs: ReturnURLs, browserMode: BrowserMode) throws {
        try CheckoutValidation.validateReturnURLs(
            success: returnURLs.success,
            cancel: returnURLs.cancel
        )
        if browserMode != .externalBrowser,
           returnURLs.success.scheme?.lowercased() != "https",
           returnURLs.success.scheme?.caseInsensitiveCompare(returnURLs.cancel.scheme ?? "") != .orderedSame {
            throw M2CCheckoutError(
                .invalidRequest,
                "in-app custom success and cancel URLs must use the same scheme"
            )
        }
    }
}
