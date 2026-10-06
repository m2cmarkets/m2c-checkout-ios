# ``M2CCheckout``

Open a hosted M2C checkout from an iOS app and reflect its advisory status.

## Overview

Create one ``M2CCheckoutClient`` for the configured return URLs and status
source. The client supports a backend-created ``CheckoutSession`` or a
publishable-key ``AuctionRequest``. Observe ``M2CCheckoutClient/states`` to
render merchant-owned progress UI and await the terminal ``CheckoutResult``.

The client result is not fulfillment authority. Grant goods only after the
merchant backend verifies M2C's signed conversion webhook.

## Return handling

The default mode uses an ephemeral `ASWebAuthenticationSession` for custom
schemes and the external browser for HTTPS callbacks. The opt-in persistent mode
uses `SFSafariViewController` for either return type and allows system-managed,
app-isolated website state without guaranteeing retention, AutoFill, or wallet
availability. Forward warm and cold returns through
``M2CCheckoutClient/handleOpenURL(_:returnURLs:)`` or
``M2CCheckoutClient/handleUserActivity(_:returnURLs:)``.

For HTTPS checkout or shop-session returns using a mobile publishable key,
register each exact origin under **Mobile return origins** in M2C Credentials.
Live keys require HTTPS; test keys also permit explicitly registered loopback
HTTP origins. Register origins without paths, queries, or fragments. This is
separate from the app's Universal Link setup and custom return schemes.

## Recovery

Call ``M2CCheckoutClient/tryResume()`` after creating the client at app launch.
Recovery stores a versioned request identifier, effective return URLs, and the
status-source description. It never stores API keys, checkout URLs, or merchant
callbacks.

The M2C status backstop is opt-in through `statusBackstop.enabled` and requires
a publishable key. URL and callback primaries retain precedence. Processing
results and retryable primary failures become eligible after
`statusBackstop.threshold`; actionable errors and task cancellation propagate.
Short ambiguous-return polls reserve a bounded final M2C read within their
existing timeout. Recovery uses the saved URL template as its primary.

`canceled` and `pendingTimeout` describe the client flow and do not prove that
payment did not happen. Keep the original request ID on the merchant backend
and reconcile it before retrying the same logical order. Recovery never invokes
the merchant's native billing fallback.

## Topics

### Client

- ``M2CCheckoutClient``
- ``M2CCheckoutConfig``
- ``M2CCheckoutPresentationContextProviding``
- ``BrowserMode``
- ``CheckoutResult``
- ``CheckoutState``

### Starting checkout

- ``CheckoutSession``
- ``AuctionRequest``
- ``CheckoutStartOptions``

### Status and fallback

- ``StatusSource``
- ``ClientStatus``
- ``FallbackContext``
- ``FallbackDecision``
- ``M2CCheckoutError``
