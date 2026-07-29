# Changelog

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
