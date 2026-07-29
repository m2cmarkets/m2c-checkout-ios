import Foundation
import M2CCheckoutCore
import UIKit

@MainActor
final class ProcessCoordinator: NSObject {
    static let shared = ProcessCoordinator()

    private var active = false
    private var bufferedURLs: [URL] = []
    private var returnContinuation: CheckedContinuation<URL?, Never>?
    private var wasBackgrounded = false
    private var waitCancelled = false
    private var hasInProcessBrowserPresentation = false
    private var expectedReturn: (requestID: String, returnURLs: ReturnURLs)?

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleDidEnterBackground(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleDidEnterBackground(_ notification: Notification) {
        didEnterBackground()
    }

    @objc private func handleDidBecomeActive(_ notification: Notification) {
        didBecomeActive()
    }

    func begin() throws {
        guard !active else {
            throw M2CCheckoutError(.invalidRequest, "another checkout is already active")
        }
        active = true
        waitCancelled = false
    }

    func finish() {
        active = false
        returnContinuation?.resume(returning: nil)
        returnContinuation = nil
        bufferedURLs.removeAll()
        wasBackgrounded = false
        waitCancelled = false
        hasInProcessBrowserPresentation = false
        expectedReturn = nil
    }

    func bindReturn(requestID: String, returnURLs: ReturnURLs) {
        expectedReturn = (requestID, returnURLs)
    }

    func ingest(_ url: URL) -> Bool {
        if let expectedReturn {
            let classification = ReturnClassifier.classify(
                returnURL: url,
                successURL: expectedReturn.returnURLs.success,
                cancelURL: expectedReturn.returnURLs.cancel,
                expectedRequestID: expectedReturn.requestID
            )
            guard classification.error == nil, classification.verdict != .unknown else {
                return false
            }
        }
        if let continuation = returnContinuation {
            returnContinuation = nil
            continuation.resume(returning: url)
        } else {
            bufferedURLs.append(url)
            if bufferedURLs.count > 8 { bufferedURLs.removeFirst() }
        }
        return true
    }

    func waitForReturn() async -> URL? {
        if !bufferedURLs.isEmpty { return bufferedURLs.removeFirst() }
        if waitCancelled {
            waitCancelled = false
            return nil
        }
        return await withCheckedContinuation { continuation in
            returnContinuation = continuation
        }
    }

    func takeBufferedURL() -> URL? {
        bufferedURLs.isEmpty ? nil : bufferedURLs.removeFirst()
    }

    func discardBufferedURLs() {
        bufferedURLs.removeAll()
    }

    func cancelWait() {
        waitCancelled = true
        returnContinuation?.resume(returning: nil)
        returnContinuation = nil
    }

    func beginInProcessBrowserPresentation() {
        hasInProcessBrowserPresentation = true
    }

    func endInProcessBrowserPresentation() {
        hasInProcessBrowserPresentation = false
    }

    func didEnterBackground() {
        wasBackgrounded = true
    }

    func didBecomeActive() {
        if hasInProcessBrowserPresentation {
            // Returning from a banking or authenticator app must not close a
            // Safari controller that is still presented inside this app.
            wasBackgrounded = false
            return
        }
        guard wasBackgrounded, let continuation = returnContinuation else { return }
        wasBackgrounded = false
        returnContinuation = nil
        continuation.resume(returning: nil)
    }
}
