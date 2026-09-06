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
protocol ShopSessionBrowserPresenting: AnyObject {
    func prepareLaunch(
        mode: BrowserMode,
        presenter: UIViewController?
    ) throws

    func launch(
        shopURL: URL,
        returnURL: URL?,
        mode: BrowserMode,
        presenter: UIViewController?
    ) async throws
}

@MainActor
final class SystemShopSessionBrowserPresenter: NSObject,
    ShopSessionBrowserPresenting {
    private static var activePresenter: SystemShopSessionBrowserPresenter?

    private let safariPresentationDriver: SafariPresentationDriving
    private var safariViewController: SFSafariViewController?
    private weak var presentationHost: UIViewController?
    private var returnURL: URL?
    private var presentationCompleted = false
    private var dismissAfterPresentation = false

    override init() {
        safariPresentationDriver = UIKitSafariPresentationDriver()
        super.init()
    }

    init(safariPresentationDriver: SafariPresentationDriving) {
        self.safariPresentationDriver = safariPresentationDriver
        super.init()
    }

    func prepareLaunch(
        mode: BrowserMode,
        presenter: UIViewController?
    ) throws {
        if mode == .externalBrowser || presenter == nil { return }
        try validateInAppPresentation(presenter)
    }

    func launch(
        shopURL: URL,
        returnURL: URL?,
        mode: BrowserMode,
        presenter: UIViewController?
    ) async throws {
        if mode == .externalBrowser || presenter == nil {
            try await openExternal(shopURL)
            return
        }
        try validateInAppPresentation(presenter)
        guard let presenter else { return }
        let controller = SFSafariViewController(url: shopURL)
        controller.delegate = self
        safariViewController = controller
        presentationHost = presenter
        self.returnURL = returnURL
        Self.activePresenter = self
        try await withCheckedThrowingContinuation { continuation in
            let attempt = ShopSafariPresentationAttempt(continuation)
            let presentationError = M2CCheckoutError(
                .invalidRequest,
                "shop browser could not be presented"
            )
            safariPresentationDriver.present(
                controller,
                from: presenter
            ) { [weak self] in
                guard let self,
                      Self.activePresenter === self,
                      self.safariViewController === controller else {
                    attempt.succeed()
                    return
                }
                guard self.safariPresentationDriver.isPresentationActive(
                    controller,
                    from: presenter
                ) else {
                    self.finishPresentation(dismiss: false)
                    attempt.fail(presentationError)
                    return
                }
                self.presentationCompleted = true
                if self.dismissAfterPresentation {
                    self.finishPresentation(dismiss: true)
                }
                attempt.succeed()
            }
            DispatchQueue.main.async { [weak self, weak controller, weak presenter] in
                guard let self, let controller, let presenter,
                      Self.activePresenter === self,
                      self.safariViewController === controller else {
                    attempt.succeed()
                    return
                }
                guard !self.safariPresentationDriver.isPresentationActive(
                    controller,
                    from: presenter
                ) else { return }
                self.finishPresentation(dismiss: false)
                attempt.fail(presentationError)
            }
        }
    }

    private func validateInAppPresentation(_ presenter: UIViewController?) throws {
        if let activePresenter = Self.activePresenter,
           activePresenter.presentationCompleted,
           !activePresenter.isPresentationActive {
            activePresenter.finishPresentation(dismiss: false)
        }
        guard let presenter,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed,
              presenter.transitionCoordinator == nil else {
            throw M2CCheckoutError(
                .invalidRequest,
                "shop presentation view controller is not available"
            )
        }
        guard Self.activePresenter == nil else {
            throw M2CCheckoutError(
                .invalidRequest,
                "a shop browser is already presented"
            )
        }
    }

    private var isPresentationActive: Bool {
        guard let controller = safariViewController,
              let host = presentationHost,
              host.viewIfLoaded?.window != nil else { return false }
        return safariPresentationDriver.isPresentationActive(
            controller,
            from: host
        )
    }

    static func handleOpenURL(_ url: URL) -> Bool {
        guard let presenter = activePresenter,
              let returnURL = presenter.returnURL,
              ReturnURLMatcher.matches(url, configured: returnURL) else {
            return false
        }
        if presenter.presentationCompleted {
            presenter.finishPresentation(dismiss: true)
        } else {
            presenter.dismissAfterPresentation = true
        }
        return true
    }

    private func finishPresentation(dismiss: Bool) {
        guard Self.activePresenter === self else { return }
        Self.activePresenter = nil
        returnURL = nil
        presentationCompleted = false
        dismissAfterPresentation = false
        presentationHost = nil
        let controller = safariViewController
        safariViewController = nil
        controller?.delegate = nil
        if dismiss, let controller {
            safariPresentationDriver.dismiss(
                controller,
                animated: true,
                completion: nil
            )
        }
    }

    private func openExternal(_ url: URL) async throws {
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        guard opened else {
            throw M2CCheckoutError(.network, "system browser could not open shop")
        }
    }
}

@MainActor
private final class ShopSafariPresentationAttempt {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() {
        take()?.resume()
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        let value = continuation
        continuation = nil
        return value
    }
}

extension SystemShopSessionBrowserPresenter: @preconcurrency SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard controller === safariViewController else { return }
        finishPresentation(dismiss: false)
    }
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

    func isPresentationActive(
        _ controller: SFSafariViewController,
        from host: UIViewController
    ) -> Bool
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

    func isPresentationActive(
        _ controller: SFSafariViewController,
        from host: UIViewController
    ) -> Bool {
        host.presentedViewController === controller ||
            controller.presentingViewController != nil ||
            controller.viewIfLoaded?.window != nil
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
        guard !host.isBeingPresented,
              !host.isBeingDismissed,
              host.transitionCoordinator == nil else {
            throw M2CCheckoutError(
                .invalidRequest,
                "checkout presentation view controller is not available"
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            safariContinuation = continuation
            let controller = SFSafariViewController(url: checkoutURL)
            controller.delegate = self
            safariViewController = controller
            let presentationError = M2CCheckoutError(
                .invalidRequest,
                "checkout browser could not be presented"
            )
            ProcessCoordinator.shared.beginInProcessBrowserPresentation()
            safariPresentationDriver.present(
                controller,
                from: host
            ) { [weak self, weak controller, weak host] in
                guard let self, let controller,
                      self.safariViewController === controller,
                      self.safariContinuation != nil else { return }
                guard let host else {
                    self.settleSafari(.failure(presentationError), dismiss: false)
                    return
                }
                guard self.safariPresentationDriver.isPresentationActive(
                    controller,
                    from: host
                ) else {
                    self.settleSafari(.failure(presentationError), dismiss: false)
                    return
                }
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
            DispatchQueue.main.async { [weak self, weak controller, weak host] in
                guard let self, let controller,
                      self.safariViewController === controller,
                      self.safariContinuation != nil else { return }
                guard let host else {
                    self.settleSafari(.failure(presentationError), dismiss: false)
                    return
                }
                guard !self.safariPresentationDriver.isPresentationActive(
                    controller,
                    from: host
                ) else { return }
                self.settleSafari(.failure(presentationError), dismiss: false)
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
        settleSafari(.success(outcome), dismiss: dismiss)
    }

    private func settleSafari(
        _ result: Result<BrowserOutcome, Error>,
        dismiss: Bool
    ) {
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
        let settle = { continuation.resume(with: result) }
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
