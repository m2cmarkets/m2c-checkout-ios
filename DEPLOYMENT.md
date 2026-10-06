# iOS integration and deployment

This guide takes an iOS app from a sandbox checkout to TestFlight or App Store
deployment. The package supports iOS 14 and newer and uses Swift tools 5.9.

## 1. Create the mobile key and return URLs

In the M2C dashboard:

1. Open **Credentials**, select **Test**, and create a **Publishable Key** for
   **Mobile app**.
2. Add the app's real bundle identifier, such as `com.example.mygame`. This is
   an integration label, not a secret or an entitlement check.
3. Edit the key's custom return schemes and add an app-specific scheme such as
   `mygame`. Enter only the scheme, without `://`.
4. Copy the resulting `pub_test_...` key.

Use distinct success and cancel paths under the same scheme:

```text
mygame://checkout/return
mygame://checkout/cancel
```

The registered scheme must match the scheme sent in both URLs. Use only a
publishable key in the app. A secret key must stay on the merchant backend.

Repeat this setup under **Live** before a production rollout. Keeping a separate
mobile key per app and environment makes rotation and incident response clearer.

For HTTPS checkout or shop-session return URLs, also add each exact origin
(for example, `https://checkout.example.com`) under **Mobile return origins** on
that mobile publishable key. Register the origin without a path, query, or
fragment. Live keys require HTTPS; test keys additionally allow explicitly
registered loopback HTTP origins. An empty list blocks HTTP(S) returns.
This registration is separate from Universal Links and from the custom schemes.

## 2. Add the Swift package

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/m2cmarkets/m2c-checkout-ios.git
```

Choose the `M2CCheckout` product and a released semantic version. For a
pre-1.0 SDK, pinning an exact version gives the most predictable production
builds.

Add the package as source. Do not copy a built `.swiftmodule`, framework, or
DerivedData product into the app. SwiftPM compiles the package for the selected
device or simulator architecture and avoids `arm64` versus `x86_64` module
errors.

For a local checkout of the SDK, add its repository root as a local package.
The checked-in sample already references the local package root and can be
opened at `Examples/CheckoutSample/CheckoutSample.xcodeproj`.

## 3. Register the return route

### Custom URL scheme

In the app target, open **Info > URL Types** and add `mygame` under **URL
Schemes**. The equivalent `Info.plist` entry is:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>mygame</string>
    </array>
  </dict>
</array>
```

Forward URLs to the SDK. In SwiftUI:

```swift
private let checkoutReturnURLs = ReturnURLs(
    success: URL(string: "mygame://checkout/return")!,
    cancel: URL(string: "mygame://checkout/cancel")!
)

WindowGroup {
    ContentView()
        .onOpenURL {
            M2CCheckoutClient.handleOpenURL(
                $0,
                returnURLs: checkoutReturnURLs
            )
        }
}
```

UIKit apps should forward `application(_:open:options:)` or the corresponding
scene-delegate URL-context callback to `handleOpenURL`.

The default privacy-preferred mode uses an ephemeral
`ASWebAuthenticationSession` for custom schemes. HTTPS returns use the external
browser, so the default is not a universal ephemerality guarantee. The SDK
observes the normal application lifecycle. The explicit
`notifyDidEnterBackground` and `notifyDidBecomeActive` methods are available only
for unusual lifecycle bridges.

### Universal Links

HTTPS return URLs use the external browser in the default and external modes;
persistent mode keeps them in `SFSafariViewController`. Every mode still needs
the same Universal Link setup:

1. Add the **Associated Domains** capability to the app target with
   `applinks:checkout.example.com`.
2. Serve a valid `apple-app-site-association` file for the production Team ID,
   bundle ID, and both exact return paths.
3. Forward `NSUserActivityTypeBrowsingWeb` activities to the SDK.

Configure the client with the associated HTTPS paths instead of the custom
scheme URLs:

```swift
let checkoutReturnURLs = ReturnURLs(
    success: URL(string: "https://checkout.example.com/checkout/return")!,
    cancel: URL(string: "https://checkout.example.com/checkout/cancel")!
)
```

SwiftUI forwarding looks like this:

```swift
.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
    M2CCheckoutClient.handleUserActivity(
        $0,
        returnURLs: checkoutReturnURLs
    )
}
```

UIKit apps should forward `application(_:continue:restorationHandler:)` or the
scene-delegate equivalent. Verify Universal Links on a signed physical-device
build. Typing or pasting a URL into Safari is not a reliable association test.

## 4. Create and resume the client

For client-initiated checkout, configure the mobile publishable key and M2C's
advisory status source:

```swift
let checkoutClient = try M2CCheckoutClient(
    config: .init(
        publishableKey: AppConfiguration.m2cPublishableKey,
        returnURLs: checkoutReturnURLs,
        statusSource: .m2c
    )
)
```

Choose a browser mode deliberately:

| Mode | Behavior |
|---|---|
| `.inAppPreferred` (default) | Requests an ephemeral authentication session for custom-scheme returns. HTTPS returns use the external browser. |
| `.inAppPersistent` | Presents `SFSafariViewController` and allows system-managed, app-isolated website state for custom-scheme or Universal Link returns. |
| `.externalBrowser` | Opens the default browser directly. |

Persistent mode is best effort. It does not share the customer's existing Safari
session or guarantee cookie retention, AutoFill, remembered identity, or wallet
availability. Enable it with `browserMode: .inAppPersistent`, and test every
vendor and device combination you intend to support.

The publishable key is designed to ship in the app, but source control does not
need to contain environment-specific values. Inject the test or live key from
the corresponding build configuration.

After constructing the client at app launch, resume any pending checkout before
allowing another one to start:

```swift
if let recovered = try await checkoutClient.tryResume() {
    renderCheckoutResult(recovered)
}
```

A new `start` call deliberately fails while recovery is pending. Keep the client
alive for the checkout flow and cancel the owning `Task` when its UI is no longer
responsible for the operation.

## 5. Provide the presentation context and start checkout

The SDK needs an `M2CCheckoutPresentationContextProviding` object. This supplies
both the authentication-session anchor and the explicit, currently visible view
controller used by persistent mode. For a UIKit checkout screen, the controller
can provide both directly:

```swift
final class CheckoutViewController: UIViewController,
    M2CCheckoutPresentationContextProviding {
    var checkoutPresentingViewController: UIViewController? { self }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }
}
```

For SwiftUI, attach a small `UIViewControllerRepresentable` host to the checkout
view and return that attached controller. The checked-in sample demonstrates
this pattern. Do not search global windows or guess a root view controller in
the SDK.

The app can ask M2C to create the checkout session:

```swift
let result = try await checkoutClient.start(
    request: .init(
        transactionValue: 4.99,
        currency: "USD",
        description: "100 Gems",
        reference: orderID
    ),
    presentationContext: checkoutPresenter
)
```

Alternatively, a trusted backend can run the auction with a secret key and send
only the checkout URL, request ID, and TTL to the app:

```swift
let result = try await checkoutClient.start(
    session: CheckoutSession(
        checkoutURL: response.checkoutURL,
        requestID: response.requestID,
        ttl: response.ttl
    ),
    presentationContext: checkoutPresenter
)
```

Backend-created sessions do not require a publishable key when status comes
from the merchant backend.

## 6. Optional merchant status endpoint

Use a merchant status endpoint when the app should read webhook-fed status from
your backend instead of M2C's advisory endpoint:

```swift
let config = M2CCheckoutConfig(
    returnURLs: checkoutReturnURLs,
    statusSource: .url(
        template: "https://api.example.com/checkout/status/{request_id}"
    )
)
```

The template must contain `{request_id}` and use HTTPS in production. The SDK
sends a `GET` request without a secret or authorization header. Return a small
JSON object with one of these coarse values:

```json
{"status":"processing"}
```

Valid statuses are `processing`, `completed`, `failed`, and `canceled`.
Unknown or malformed values fail safe to `processing`. Keep request IDs opaque,
return no customer or entitlement data, and rate-limit the endpoint. Populate
it from the signed M2C webhook, not from the browser redirect.

An HTTP loopback URL is accepted for local development, but production must use
HTTPS and satisfy App Transport Security. `M2CStatusBackstop(enabled: true)` can
check M2C after the merchant source has remained `processing`; it also requires
a publishable key. It is customer-facing resilience, not fulfillment authority.

## 7. Handle results safely

Use `CheckoutResult` to update checkout UI. A browser return, `.completed`, or
`.fallbackStarted` must not grant goods. Fulfill and reverse purchases only from
the merchant backend after it verifies and durably processes M2C's signed,
ordered conversion webhook.

If native billing fallback is enabled, the fallback handler must start the
merchant's own StoreKit flow. `.fallbackStarted` means only that the handler
accepted responsibility.

## 8. Verify and deploy the app

Before TestFlight or App Store upload:

- Confirm the app target has a real bundle identifier, signing team, marketing
  version, and positive numeric build number. A missing bundle ID or invalid
  `CFBundleVersion` prevents simulator and device installation.
- Build the package and app for both an iOS Simulator and
  `generic/platform=iOS`. Do not rely only on the currently active architecture.
- Test a successful return, cancel, browser dismissal, backgrounding, and
  process termination in both enabled browser modes on iOS 14 and the current
  iOS release.
- Test custom-scheme and Universal Link returns on a signed physical device.
- For each checkout behavior you advertise, record the OS, vendor, SDK version,
  and whether a second checkout retained vendor state. Record AutoFill and wallet
  results separately; persistent mode does not guarantee either feature.
- Exercise the signed webhook through fulfillment with sandbox data.
- Test the live key and live registered return scheme without granting value.
- Review the app's policy eligibility, privacy notice, and App Privacy answers.
  The SDK package includes its privacy manifest and cannot read browser-managed
  website data, but the app's vendors and complete behavior control its
  disclosures.

Useful package gates from the repository root are:

```bash
swift package dump-package
xcodebuild \
  -scheme M2CCheckout \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

In Xcode, select **Any iOS Device**, choose **Product > Archive**, validate the
archive in Organizer, and distribute it through the app's normal protected
TestFlight or App Store Connect process. Repeat the return and webhook smoke test
from the distributed build.

## Troubleshooting

- **`success_url scheme is not registered for this key`**: add the exact scheme
  to that test or live mobile publishable key. Do not include `://` in the
  dashboard field.
- **Module is not built for `arm64` or `x86_64`**: remove manually embedded
  module products, use the Swift package source dependency, reset package caches,
  and clear DerivedData before rebuilding the selected simulator.
- **Simulator cannot install the app**: set a valid product bundle identifier,
  `MARKETING_VERSION`, and numeric `CURRENT_PROJECT_VERSION` on the app target.
- **Return opens the app but checkout does not settle**: forward the URL or user
  activity, keep the configured paths identical, and call `tryResume` before
  another checkout starts.
- **Custom status remains `processing`**: verify the endpoint substitutes the
  request ID, returns one supported status, and is populated by the webhook.

## Platform references

- [Add package dependencies in Xcode](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app)
- [Support associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)
- [Publish a Swift package](https://developer.apple.com/documentation/xcode/publishing-a-swift-package-with-xcode)
