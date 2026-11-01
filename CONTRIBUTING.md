# Contributing to Baseline

Thanks for your interest in improving Baseline! Bug reports, ideas, and pull requests are all welcome.

## Ways to help

- **Report a bug:** [open an issue](https://github.com/Om-Kamath/baseline/issues/new/choose) using the bug report template.
- **Suggest a feature:** open an issue using the feature request template. Explain the problem you want solved before the solution.
- **Improve the scoring:** changes to how scores are calculated are very welcome, but please include your reasoning, and a reference to published research where possible.
- **Fix something:** issues labeled `good first issue` are a good place to start.

## Setting up the project

1. Fork and clone the repository, then open `baseline.xcodeproj` in **Xcode 27** or later.
2. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set:
   - `DEVELOPMENT_TEAM`: your Apple Developer Team ID (Xcode → Settings → Accounts)
   - `PRODUCT_BUNDLE_IDENTIFIER`: something unique to you, such as `com.yourname.baseline`

   This file is ignored by git, so your personal settings are never committed.
3. Select your iPhone and press **⌘R**. HealthKit has no sample data in the Simulator, so use a real device with Apple Health data, ideally from an Apple Watch.

## Making a change

1. Create a branch from `main`, such as `fix/sleep-debt-rounding` or `feature/steps-in-body-charge`.
2. Keep pull requests focused on one change. Small PRs are reviewed faster.
3. Match the existing style:
   - SwiftUI with `@Observable` and Swift concurrency (`async`/`await`, actors); no Combine
   - 4-space indentation, `PascalCase` types, `camelCase` properties and methods
   - Comments that explain *why*, especially for anything that affects scores
   - Scoring constants belong in `HealthRecoveryUtilitiesScoringWeights.swift`
4. Make sure the project builds with no new warnings, and try your change on a device.
5. If you change how a score is calculated, update the **How the scores work** section of the README.
6. Open a pull request and fill in the template.

## Health data and privacy

Baseline's promise is that health data never leaves the user's device. Pull requests that send health data off the device, add analytics or tracking, or require an account will not be accepted.

## Code of conduct

By taking part in this project, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
