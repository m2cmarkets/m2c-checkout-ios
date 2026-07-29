import AuthenticationServices
import Foundation
import M2CCheckoutCore
import SafariServices
import UIKit

enum BrowserOutcome {
    case returned(URL)
    case dismissed
    case ambiguous
}

enum BrowserPresentationRoute: Equatable {
    case authenticationSession
    case safariViewController
    case external
}

func browserPresentationRoute(callbackURL: URL, mode: BrowserMode) -> BrowserPresentationRoute {
    if mode == .externalBrowser {
        return .external
    }
    if mode == .inAppPersistent {
        return .safariViewController
    }
    if callbackURL.scheme?.lowercased() == "https" { return .external }
    return .authenticationSession
}

@MainActor
protocol BrowserPresenting: AnyObject {
    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome
}

@MainActor
protocol SafariPresentationDriving: AnyObject {
    func present(
        _ controller: SFSafariViewController,
        from host: UIViewController,
        completion: @escaping () -> Void
    )

    func dismiss(
        _ controller: SFSafariViewController,
        animated: Bool,
        completion: (() -> Void)?
    )
}

@MainActor
private final class UIKitSafariPresentationDriver: SafariPresentationDriving {
    func present(
        _ controller: SFSafariViewController,
        from host: UIViewController,
        completion: @escaping () -> Void
    ) {
        host.present(controller, animated: true, completion: completion)
    }

    func dismiss(
        _ controller: SFSafariViewController,
        animated: Bool,
        completion: (() -> Void)?
    ) {
        guard controller.presentingViewController != nil else {
            completion?()
            return
        }
        controller.dismiss(animated: animated, completion: completion)
    }
}

@MainActor
final class SystemBrowserPresenter: NSObject, BrowserPresenting {
    private let safariPresentationDriver: SafariPresentationDriving
    private var authenticationSession: ASWebAuthenticationSession?
    private var authenticationContinuation: CheckedContinuation<BrowserOutcome, Error>?
    private var safariViewController: SFSafariViewController?
    private var safariContinuation: CheckedContinuation<BrowserOutcome, Error>?
    private var safariReturnTask: Task<Void, Never>?
    private var safariDismissalTask: Task<Void, Never>?

    override init() {
        safariPresentationDriver = UIKitSafariPresentationDriver()
        super.init()
    }

    init(safariPresentationDriver: SafariPresentationDriving) {
        self.safariPresentationDriver = safariPresentationDriver
        super.init()
    }

    func open(
        checkoutURL: URL,
        callbackURL: URL,
        mode: BrowserMode,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        try await withTaskCancellationHandler {
            switch browserPresentationRoute(callbackURL: callbackURL, mode: mode) {
            case .external:
                return try await openExternal(checkoutURL, onExposed: onExposed)
            case .safariViewController:
                return try await openSafari(
                    checkoutURL,
                    presentationContext: presentationContext,
                    onExposed: onExposed
                )
            case .authenticationSession:
                return try await openAuthenticationSession(
                    checkoutURL,
                    callbackURL: callbackURL,
                    presentationContext: presentationContext,
                    onExposed: onExposed
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActivePresentation()
            }
        }
    }

    private func openAuthenticationSession(
        _ checkoutURL: URL,
        callbackURL: URL,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        guard let callbackScheme = callbackURL.scheme else {
            throw M2CCheckoutError(.invalidRequest, "custom return URL has no scheme")
        }
        return try await withCheckedThrowingContinuation { continuation in
            authenticationContinuation = continuation
            let completion: (URL?, Error?) -> Void = {
                [weak self] url, error in
                Task { @MainActor in
                    guard let continuation = self?.takeAuthenticationContinuation() else {
                        return
                    }
                    if let url {
                        continuation.resume(returning: .returned(url))
                    } else if let authError = error as? ASWebAuthenticationSessionError,
                              authError.code == .canceledLogin {
                        continuation.resume(returning: .dismissed)
                    } else if let error {
                        continuation.resume(
                            throwing: M2CCheckoutError(
                                .network,
                                "browser session failed: \(error.localizedDescription)"
                            )
                        )
                    } else {
                        continuation.resume(returning: .ambiguous)
                    }
                }
            }
            let session = ASWebAuthenticationSession(
                url: checkoutURL,
                callbackURLScheme: callbackScheme,
                completionHandler: completion
            )
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = true
            authenticationSession = session
            guard session.start() else {
                takeAuthenticationContinuation()?.resume(
                    throwing: M2CCheckoutError(.network, "browser session could not start")
                )
                return
            }
            onExposed()
        }
    }

    private func openSafari(
        _ checkoutURL: URL,
        presentationContext: M2CCheckoutPresentationContextProviding,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        guard let host = presentationContext.checkoutPresentingViewController,
              host.viewIfLoaded?.window != nil else {
            throw M2CCheckoutError(
                .invalidRequest,
                "checkout presentation view controller is not visible"
            )
        }
        guard host.presentedViewController == nil else {
            throw M2CCheckoutError(
                .invalidRequest,
                "checkout presentation view controller is already presenting content"
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            safariContinuation = continuation
            let controller = SFSafariViewController(url: checkoutURL)
            controller.delegate = self
            safariViewController = controller
            ProcessCoordinator.shared.beginInProcessBrowserPresentation()
            safariPresentationDriver.present(
                controller,
                from: host
            ) { [weak self, weak controller] in
                guard let self,
                      self.safariViewController === controller,
                      self.safariContinuation != nil else { return }
                onExposed()
                self.safariReturnTask = Task { @MainActor [weak self] in
                    var url = await ProcessCoordinator.shared.waitForReturn()
                    guard !Task.isCancelled else { return }
                    if url == nil {
                        // App activation can precede URL delivery for custom
                        // schemes and Universal Links. Let that late URL enter
                        // the coordinator before classifying the return as
                        // ambiguous.
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        url = ProcessCoordinator.shared.takeBufferedURL()
                    }
                    self?.completeSafari(
                        url.map(BrowserOutcome.returned) ?? .ambiguous,
                        dismiss: true
                    )
                }
            }
        }
    }

    private func openExternal(
        _ url: URL,
        onExposed: @MainActor @escaping () -> Void
    ) async throws -> BrowserOutcome {
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        guard opened else {
            throw M2CCheckoutError(.network, "system browser could not open checkout")
        }
        onExposed()
        try Task.checkCancellation()
        if let url = await ProcessCoordinator.shared.waitForReturn() {
            return .returned(url)
        }
        try Task.checkCancellation()
        return .ambiguous
    }

    private func takeAuthenticationContinuation() -> CheckedContinuation<BrowserOutcome, Error>? {
        let continuation = authenticationContinuation
        authenticationContinuation = nil
        authenticationSession = nil
        return continuation
    }

    private func completeSafari(_ outcome: BrowserOutcome, dismiss: Bool) {
        guard let continuation = safariContinuation else { return }
        safariContinuation = nil
        safariReturnTask?.cancel()
        safariReturnTask = nil
        safariDismissalTask?.cancel()
        safariDismissalTask = nil
        ProcessCoordinator.shared.endInProcessBrowserPresentation()
        ProcessCoordinator.shared.cancelWait()
        let controller = safariViewController
        safariViewController = nil
        controller?.delegate = nil
        let settle = { continuation.resume(returning: outcome) }
        if dismiss, let controller {
            safariPresentationDriver.dismiss(controller, animated: true, completion: settle)
        } else {
            settle()
        }
    }

    private func cancelActivePresentation() {
        authenticationSession?.cancel()
        takeAuthenticationContinuation()?.resume(throwing: CancellationError())
        if let continuation = safariContinuation {
            safariContinuation = nil
            safariReturnTask?.cancel()
            safariReturnTask = nil
            safariDismissalTask?.cancel()
            safariDismissalTask = nil
            ProcessCoordinator.shared.endInProcessBrowserPresentation()
            let controller = safariViewController
            safariViewController = nil
            controller?.delegate = nil
            if let controller {
                // Cancellation must not depend on a UIKit transition callback.
                // A stalled presentation would otherwise leave the checkout
                // task suspended indefinitely while waiting for dismissal.
                safariPresentationDriver.dismiss(
                    controller,
                    animated: false,
                    completion: nil
                )
            }
            continuation.resume(throwing: CancellationError())
        }
        ProcessCoordinator.shared.cancelWait()
    }
}

extension SystemBrowserPresenter: @preconcurrency SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard controller === safariViewController,
              safariContinuation != nil,
              safariDismissalTask == nil else { return }
        // A return URL and the Done gesture can arrive in either order. Give an
        // already-dispatched return a brief chance to win, then reconcile the
        // status because a later return is indistinguishable from dismissal.
        safariDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.completeSafari(.ambiguous, dismiss: false)
        }
    }
}
