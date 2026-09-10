# ClearPath Finance

ClearPath is a privacy-first Flutter app for tracking credit cards, debit cards,
cash withdrawals, loans, installments, spending categories, and salary-aware
debt payoff plans.

## Features

- Google OAuth Gmail import for BHD, APAP, and Banreservas notifications
- Credit and debit account detection from the last four digits
- Purchases, cash withdrawals, payments, refunds, salary, and adjustments
- Manual balance calibration, cutoff dates, due dates, APRs, and installments
- Loans with due dates, APRs, minimums, and reminders
- Spending analytics by category and month
- Explainable debt-avalanche payoff timeline with a month slider
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
