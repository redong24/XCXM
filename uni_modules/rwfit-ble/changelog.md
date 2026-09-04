## Unreleased

- Replaced the iOS framework with an XCFramework containing device and
  simulator slices, enabling iOS Simulator builds and execution.

## 0.0.1

- Added the unified Flutter-compatible public contract.
- Added Android, iOS, HarmonyOS NEXT, and WeChat Mini Program adapters
  implementing the Flutter-compatible health, workout, device-setting,
  sensor, synchronization, notification, and OTA bridge APIs.
- Added the bilingual (Chinese/English) uni-app Vue 3 demo, matching the
  WeChat SDK demo's page structure: health home, search, device settings,
  history, workouts, and OTA, with normalized persistent events and explicit
  unsupported-platform errors.
