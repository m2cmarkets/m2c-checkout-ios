# M2C Checkout for iOS

`M2CCheckout` is the headless iOS checkout SDK. It supports backend-created
checkout sessions and mobile publishable-key auctions on iOS 14 and newer.
Add `https://github.com/m2cmarkets/m2c-checkout-ios.git` in Swift Package
Manager, select the `M2CCheckout` product, choose a released semantic version,
and import `M2CCheckout`.

Current version: `0.8.1`.

See [DEPLOYMENT.md](DEPLOYMENT.md) for the complete dashboard, return-routing,
status-endpoint, release-build, and TestFlight or App Store deployment setup.

## Test app

Open `Examples/CheckoutSample/CheckoutSample.xcodeproj` to run the local-package
smoke-test app. Enter a `pub_test_` key whose registered mobile return scheme is
`m2csample`, then use it to start checkout, exercise an eligible billing
fallback, resume an interrupted flow, or recheck the last request's status.
The on-screen log shows every SDK state and terminal result. Use sandbox data
only.

```swift
let returnURLs = ReturnURLs(
    success: URL(string: "mygame://checkout/return")!,
    cancel: URL(string: "mygame://checkout/cancel")!
)

let client = try M2CCheckoutClient(
    config: .init(
        publishableKey: "pub_test_...",
        returnURLs: returnURLs,
        statusSource: .m2c
    )
)

let result = try await client.start(
    request: .init(
        transactionValue: 4.99,
        currency: "USD",
        description: "100 Gems",
        reference: "order_123"
    ),
    presentationContext: presentationProvider
)
```

Forward custom-scheme and Universal Link returns from the app or scene delegate:

```swift
M2CCheckoutClient.handleOpenURL(url, returnURLs: returnURLs)
M2CCheckoutClient.handleUserActivity(userActivity, returnURLs: returnURLs)
```

For custom-scheme returns, register the scheme in the app target's
`CFBundleURLTypes`:

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

The SDK observes background and active lifecycle events for external-browser
returns. The `notifyDidEnterBackground()` and `notifyDidBecomeActive()` methods
remain available for unusual lifecycle bridges, but normal UIKit and SwiftUI
apps do not need to call them. Universal Links require an Associated Domains
entitlement and matching AASA paths for both the success and cancel URLs.

Call `tryResume()` after recreating the client at app launch. A pending recovery
must be resumed before `start`; a new start fails with `invalidRequest` instead
of replacing the earlier checkout record.

## Browser modes

| Mode | iOS surface | Browser state |
|---|---|---|
| `.inAppPreferred` (default) | Ephemeral `ASWebAuthenticationSession` for custom-scheme returns; external browser for HTTPS returns | Privacy-preferred. HTTPS returns and future compatibility fallbacks are not an ephemerality guarantee. |
| `.inAppPersistent` | `SFSafariViewController` | Allows system-managed, app-isolated website state. Retention, autofill, and wallet availability depend on the vendor page, device, region, and OS. It does not share the customer's existing Safari session. |
| `.externalBrowser` | Default browser | Uses the browser's normal state and requires the app to forward the configured return URL. |

All modes require an `M2CCheckoutPresentationContextProviding` object. Persistent
mode uses its explicit `checkoutPresentingViewController`; provide the currently
visible controller rather than making the SDK infer one from global windows.
Persistent mode may leave vendor-controlled website data on the device. The SDK
cannot read or manipulate that data. Test each intended vendor and device
combination before describing remember-me, AutoFill, or wallet support.

The SDK never grants an entitlement. Fulfill purchases only from M2C's signed
server webhook. `fallbackStarted` means the merchant's native billing handler
accepted responsibility; it does not mean a StoreKit purchase completed.

## Privacy and data handling

The SDK contains no advertising, cross-app tracking, fingerprinting, or device-ID
code. For client-initiated checkout it sends the transaction context supplied by
the app to M2C and uses the connection IP for server-side country resolution. It
stores only purchase-scoped recovery data in `UserDefaults` and clears that state
after the flow is resolved. A merchant status URL is called only when the app
configures one.

The package includes `PrivacyInfo.xcprivacy`, declaring the SDK's transaction
context and required-reason use of `UserDefaults`. Your app remains responsible
for its complete App Privacy disclosure, privacy notice, retention behavior, and
the behavior of every other component it ships. That review includes vendor
website data retained by a persistent browser surface even though the SDK cannot
access it. Review the actual integration and applicable requirements rather than
copying a generic disclosure answer.

## App Store policy

The SDK is checkout transport, not a determination that external checkout is
permitted. Store rules vary by product category, region, program, and checkout
surface. The merchant must confirm that each use is permitted and complete any
required entitlement, disclosure, or alternative-billing work before enabling
it. Native billing fallback remains the merchant's own StoreKit integration.
