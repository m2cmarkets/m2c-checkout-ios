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

## Recovery

Call ``M2CCheckoutClient/tryResume()`` after creating the client at app launch.
Recovery stores a versioned request identifier, effective return URLs, and the
status-source description. It never stores API keys, checkout URLs, or merchant
callbacks.

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
