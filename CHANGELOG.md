# Changelog

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
