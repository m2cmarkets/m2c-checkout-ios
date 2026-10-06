# Changelog

## 0.11.0 - 2026-10-05

- Polling and recovery retain one read permit per primary or backstop request,
  allowing healthy reads while earlier cancellation-insensitive reads finish.
- Opt-in status backstops now handle retryable primary failures and saved URL
  recovery. Short ambiguous-return polls reserve a bounded final backstop read.
- Preserve primary results, actionable errors, task cancellation, and existing
  recovery cleanup. Clarify reconciliation before retrying an uncertain payment.
- Document registered mobile HTTP(S) return origins for checkout and shop sessions.

## 0.10.0 - 2026-10-01

- **Breaking:** `reference` must be an opaque ID: 1-128 ASCII letters, digits,
  `.`, `_`, `:` or `-` after trimming. The SDK now rejects anything else
  client-side instead of sending it; M2C rejects it with `400` either way.
- **Breaking:** Plain-HTTP checkout URLs qualify for the loopback exception only
  when the raw URL text names a loopback host. Percent-encoded hosts and URLs
  with more than one userinfo separator are now rejected.
- M2C now accepts only its fixed segment list (`new_customer`,
  `returning_customer`, `guest`, `verified`, `subscriber`, `trial`, `lapsed`,
  `high_value`) and reduces `referrer` to its origin. The SDK passes segments
  through unchanged, so the list can grow without an SDK release.

## 0.9.0 - 2026-08-30

- Added `M2CShopSessionClient`, return-driven in-app Safari dismissal, immutable
  session handles, and one-shot strict status reads.
- Added the shared session-status vectors and `sessionNotFound` error code.

## 0.8.2 - 2026-08-25

- Aligned the checkout SDK release train and documented the browser-tab session
  bridge. No native shop-session API was added.

## 0.8.1 - 2026-07-29

- Removed the standalone support, security, and contribution documents and
  their README links. No runtime behavior changed in this release.

## 0.8.0 - 2026-07-29

- Aligned the iOS checkout SDK with the browser, Android, and Unity release
  train at version 0.8.0.
- Initial headless iOS checkout client.
- Backend and publishable-key starts, status polling, browser returns, recovery,
  and merchant-owned native billing fallback.
- Automatic external-browser lifecycle return detection, bounded dismissal
  reconciliation, strict callback matching, and merchant status URL handling.
- Opt-in persistence-preferred `SFSafariViewController` checkout with an explicit
  merchant presentation host and return-versus-dismissal reconciliation.
