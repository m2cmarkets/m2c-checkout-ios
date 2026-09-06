import AuthenticationServices
import M2CCheckout
import SwiftUI
import UIKit

private let sampleReturnURLs = ReturnURLs(
    success: URL(string: "m2csample://checkout/return")!,
    cancel: URL(string: "m2csample://checkout/cancel")!
)

@main
struct CheckoutSampleApp: App {
    var body: some Scene {
        WindowGroup {
            CheckoutView()
                .onOpenURL {
                    guard !M2CShopSessionClient.handleOpenURL($0) else { return }
                    M2CCheckoutClient.handleOpenURL($0, returnURLs: sampleReturnURLs)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
                    guard !M2CShopSessionClient.handleUserActivity($0) else { return }
                    M2CCheckoutClient.handleUserActivity(
                        $0,
                        returnURLs: sampleReturnURLs
                    )
                }
        }
    }
}

@MainActor
private final class SampleModel: NSObject, ObservableObject,
    M2CCheckoutPresentationContextProviding {
    @Published var publishableKey = "pub_test_replace_me"
    @Published var amount = "4.99"
    @Published var currency = "USD"
    @Published var persistentBrowser = false
    @Published var log = "Ready"
    @Published var busy = false

    weak var checkoutPresentingViewController: UIViewController?
    private var client: M2CCheckoutClient?
    private var stateTask: Task<Void, Never>?
    private var lastRequestID: String?
    private var lastSessionID: String?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        checkoutPresentingViewController?.view.window ?? ASPresentationAnchor()
    }

    func start(fallbackEnabled: Bool) {
        guard let value = Decimal(string: amount), !currency.isEmpty else {
            append("Invalid amount or currency")
            return
        }
        run {
            let client = try self.makeClient(fallbackEnabled: fallbackEnabled)
            let result = try await client.start(
                request: .init(
                    transactionValue: value,
                    currency: self.currency,
                    description: "Native SDK test item",
                    reference: UUID().uuidString
                ),
                presentationContext: self,
                options: .init(fallbackProductID: "m2c_test_product")
            )
            self.record(result)
        }
    }

    func resume() {
        run {
            let client = try self.makeClient(fallbackEnabled: false)
            guard let result = try await client.tryResume() else {
                self.append("Nothing to resume")
                return
            }
            self.record(result)
        }
    }

    func checkStatus() {
        guard let requestID = lastRequestID else {
            append("No request to check")
            return
        }
        run {
            let client = try self.makeClient(fallbackEnabled: false)
            let status = try await client.checkStatus(requestID: requestID)
            self.append("status \(requestID) -> \(status.rawValue)")
        }
    }

    func startShopSession() {
        run {
            let client = try M2CShopSessionClient(
                config: M2CSessionConfig(
                    publishableKey: self.publishableKey,
                    browserMode: self.persistentBrowser ? .inAppPersistent : .inAppPreferred
                )
            )
            let handle = try await client.startShopSession(
                ShopSessionRequest(
                    currency: self.currency,
                    returnURL: URL(string: "m2csample://shop/closed")
                ),
                from: self.checkoutPresentingViewController
            )
            self.lastSessionID = handle.sessionID
            self.append("shop session \(handle.sessionID)")
        }
    }

    func refreshShopSession() {
        guard let sessionID = lastSessionID else {
            append("No shop session to check")
            return
        }
        run {
            let client = try M2CShopSessionClient(
                config: M2CSessionConfig(publishableKey: self.publishableKey)
            )
            let status = try await client.readShopSessionStatus(sessionID: sessionID)
            self.append("shop \(status.status.rawValue): \(status.completedPurchases) purchases")
        }
    }

    func clearLog() {
        log = ""
    }

    private func makeClient(fallbackEnabled: Bool) throws -> M2CCheckoutClient {
        stateTask?.cancel()
        let fallback: CheckoutFallbackHandler?
        if fallbackEnabled {
            fallback = { [weak self] reason, context in
                self?.append("FALLBACK WORKED: \(reason.rawValue), attempt \(context.attemptID)")
                return .accepted
            }
        } else {
            fallback = nil
        }
        let client = try M2CCheckoutClient(
            config: .init(
                publishableKey: publishableKey,
                returnURLs: sampleReturnURLs,
                statusSource: .m2c,
                browserMode: persistentBrowser ? .inAppPersistent : .inAppPreferred,
                fallbackHandler: fallback
            )
        )
        self.client = client
        stateTask = Task { [weak self, weak client] in
            guard let client else { return }
            for await state in client.states {
                self?.append("state -> \(state.rawValue)")
            }
        }
        return client
    }

    private func run(_ operation: @MainActor @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await operation()
            } catch is CancellationError {
                append("Canceled by test app")
            } catch let error as M2CCheckoutError {
                append("ERROR \(error.code.rawValue): \(error.message)")
            } catch {
                append("EXCEPTION: \(error.localizedDescription)")
            }
        }
    }

    private func record(_ result: CheckoutResult) {
        switch result {
        case .completed(let requestID),
             .failed(let requestID),
             .canceled(let requestID),
             .pendingTimeout(let requestID):
            lastRequestID = requestID
        case .fallbackStarted(_, let requestID, _):
            lastRequestID = requestID
        }
        append("RESULT: \(String(describing: result))")
    }

    private func append(_ message: String) {
        log += (log.isEmpty ? "" : "\n") + message
    }
}

private struct CheckoutView: View {
    @StateObject private var model = SampleModel()

    var body: some View {
        Form {
            Section(header: Text("Sandbox settings")) {
                TextField("pub_test_...", text: $model.publishableKey)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("Amount", text: $model.amount)
                    .keyboardType(.decimalPad)
                TextField("Currency", text: $model.currency)
                    .autocapitalization(.allCharacters)
                Toggle("Persistent browser state", isOn: $model.persistentBrowser)
            }
            Section(header: Text("Actions")) {
                Button("Start checkout") { model.start(fallbackEnabled: false) }
                Button("Fallback test") { model.start(fallbackEnabled: true) }
                Button("Try resume") { model.resume() }
                Button("Check status") { model.checkStatus() }
                Button("Open shop session") { model.startShopSession() }
                Button("Refresh shop status") { model.refreshShopSession() }
                Button("Clear log") { model.clearLog() }
            }
            .disabled(model.busy)
            Section(header: Text("Log")) {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .background(
            PresentationHostReader { model.checkoutPresentingViewController = $0 }
        )
    }
}

private struct PresentationHostReader: UIViewControllerRepresentable {
    let onResolve: (UIViewController?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        DispatchQueue.main.async { onResolve(controller) }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        DispatchQueue.main.async { onResolve(controller) }
    }

    static func dismantleUIViewController(
        _ controller: UIViewController,
        coordinator: Void
    ) {
        // The model holds this weakly, so SwiftUI teardown releases the host.
    }
}
