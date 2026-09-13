# ClearPath Finance

ClearPath is a privacy-first Flutter app for tracking credit cards, debit cards,
cash withdrawals, loans, installments, spending categories, and salary-aware
debt payoff plans.

## Features

- Provider picker for Gmail, Outlook/Microsoft 365, and iCloud Mail
- Live read-only Gmail import with setup guidance for Outlook and iCloud
- Dominican-bank alert recognition with a generic structured-alert fallback
- Credit and debit account detection from the last four digits in DOP or USD
- Purchases, cash withdrawals, payments, refunds, salary, and incoming/outgoing transfers
- Manual balance calibration, cutoff dates, due dates, APRs, and installments
- Loans with due dates, APRs, minimums, and reminders
- Spending analytics by category, month, merchant, and weekday
- Salary-percentage or fixed-budget debt payoff calendar with ICS reminder export
- Local-only financial storage; each browser profile owns its own data

## Run locally

```sh
flutter pub get
flutter run -d chrome
```

## Verify

```sh
flutter analyze
flutter test
flutter build web --release --pwa-strategy=none
flutter build ios --release --no-codesign
```

Gmail access uses the OAuth client ID declared in `web/index.html`. Production
access for accounts outside the Google OAuth test-user list requires publishing
and verifying the Google consent screen.

Outlook requires a Microsoft Entra application with delegated `Mail.Read`.
iCloud Mail cannot be read by a static browser app; it needs Apple-authorized
account access or a secure server/native IMAP bridge.
