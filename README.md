# APIUsageStatus

> **Languages:** English | [简体中文](README_zh-CN.md)

A pure menu bar macOS app designed for macOS 13 that monitors MiniMax / DeepSeek API usage and balance in real time.
**Since mainstream similar apps don't support macOS 13, this project is only a self-use scaffold project.**

## Features

- **Menu Bar Icon** — rendered in SF Pro 8pt, two-line stacked layout, showing usage status for up to 2 instances simultaneously
- **Usage Panel** — click the icon to pop up a floating window showing usage cards, error summary, manual refresh, and a settings entry
- **Weekly Quota Display** — MiniMax instance card shows a weekly window progress bar at the bottom; unlimited plans display a cyan-blue flowing glow bar animation
- **Threshold Alerts** — quota percentages or balance amounts trigger macOS system notifications; click the notification to view details
- **Balance Tracking** — records historical snapshots, displays daily averages by week / month / last 7 days / last 30 days
- **Zero External Dependencies** — only uses system frameworks like AppKit, SwiftUI, Security

<img src="docs/README_assets/ScreenShot.png" alt="Usage Panel Screenshot" style="max-width: 100%;">

### Supported Providers

| Provider | Monitoring Dimension | API Endpoint |
|----------|---------------------|--------------|
| MiniMax | Remaining percentage of the 5h window and weekly window for each `model_name` (e.g. `general` text, `video` non-text) | `www.minimaxi.com/v1/token_plan/remains` |
| DeepSeek | Topped-up amount, gifted amount, total balance, currency unit | `api.deepseek.com/user/balance` |

## System Requirements

| Item | Requirement |
|------|-------------|
| macOS | ≥ 13.0 (Ventura) |
| Xcode | ≥ 14.3 (Swift 5.9) |
| Optional | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for regenerating .xcodeproj) |

## Build & Run

### 1. Generate Xcode Project (if needed)

```bash
brew install xcodegen
xcodegen generate
```

### 2. Command Line Build

```bash
# Debug build
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Debug \
  build

# Release build (ad-hoc signed)
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Release \
  build
```

### 3. Run in Xcode

```bash
open APIUsageStatus.xcodeproj
```

Then press Cmd+R to run. After the app launches, a `?` icon will appear in the menu bar (no Dock icon).

### 4. First-time Setup

1. Click the menu bar icon → **Settings**
2. Click **+** to add an instance
3. Choose the provider, fill in the dimension, enter the API Key (stored in Keychain)
4. Configure alert thresholds
5. The menu bar icon will automatically refresh to reflect usage status

## Running Tests

```bash
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Debug \
  test
```

Or press Cmd+U in Xcode.

### Test Suites (64 cases in total, excluding deprecated)

| Suite | Count | Coverage |
|-------|-------|----------|
| BalanceCalculatorTests | 14 | Consumption calculation, cross-day archiving, top-up detection, daily average statistics, history trimming |
| MiniMaxResponseParserTests | 10 | Normal parsing, auth errors, business errors, malformed JSON, multiple models, weekly fields |
| DeepSeekResponseParserTests | 8 | CNY priority parsing, fallback, `is_available=false`, empty array |
| RetryPolicyTests | 6 | Retry behavior, backoff delay, max attempts |
| WeeklyQuotaTests | 10 | Weekly field parsing, `isUnlimited` judgment, missing field fallback |
| FlowingGlowBarTests | 5 | Glow bar phase, width, geometry constraints |
| MenuBarIconRendererTests | 11 | Snapshot comparison tests for all icon states |
| ~~PixelFontEngineTests~~ | ~~58~~ | ~~(Deprecated) Original pixel font engine tests; code is commented out and does not run~~ |

## Deploy to /Applications

```bash
# Copy the Release bundle
cp -R build/Release/APIUsageStatus.app /Applications/

# First launch needs to bypass Gatekeeper (right-click → Open), or run:
xattr -cr /Applications/APIUsageStatus.app
```

Then enable "Launch at Login" in the app's Settings.

## Project Structure

```
APIUsageStatus/
├── APIUsageStatusApp.swift        # @main entry + NSApplicationDelegate
├── MenuBar/                       # Menu bar icon and usage panel controllers
├── Views/                         # SwiftUI views (panel/card/settings/details)
├── AppState/                      # Runtime state Actor + @MainActor proxy
├── Models/                        # Data models (instance/balance/threshold/global settings)
├── Services/                      # Core services (Keychain/persistence/refresh/notification/launch at login)
├── Network/                       # HTTP client + retry policy
├── Suppliers/                     # Provider protocol + MiniMax / DeepSeek implementations
├── Balance/                       # Balance calculator + history snapshots
├── PixelFont/                     # ⚠️ Deprecated: original pixel font engine (code commented out)
├── Extensions/                    # Date/Decimal/String extensions
├── Utilities/                     # Logging + atomic writes
├── Resources/                     # Info.plist + AppIcon source files
└── Assets.xcassets/               # Compiled AppIcon asset catalog
APIUsageStatusTests/
├── BalanceCalculatorTests.swift
├── MiniMaxResponseParserTests.swift
├── DeepSeekResponseParserTests.swift
├── RetryPolicyTests.swift
├── WeeklyQuotaTests.swift
├── FlowingGlowBarTests.swift
├── MenuBarIconRendererTests.swift
├── ~~PixelFontEngineTests.swift~~  # Deprecated (code commented out)
└── ReferenceImages/               # Snapshot test golden images
```

## Security & Privacy

- **App Sandbox** — all file I/O is restricted to the sandbox container
- **API Key** — stored in Keychain (InternetPassword type), never written to disk in plain text
- **Network** — only HTTPS access to provider APIs, no user data transmitted
- **Logging** — os.Logger, sensitive information automatically masked in production