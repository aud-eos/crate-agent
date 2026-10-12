# Test isolation

Run `make test-swift` (or `make test` for Rust and Swift). Build the Rust library
and bindings with `make build-rust` first on a fresh checkout.

The generated CrateAgent scheme uses the **Test** configuration for its Test
action. That configuration compiles `CRATE_AGENT_TEST_HOST` into the app and uses
`com.crateagent.CrateAgent.TestHost` as its bundle identifier. It therefore stays
inactive before XCTest loads, and AppKit window state uses a separate preferences
domain. Normal Debug/Release launches retain the production startup path.

For a direct command:

```sh
xcodegen generate
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent \
  -configuration Test -derivedDataPath build-output/DerivedData test
```

Do not override the test configuration with Debug or Release. Runtime XCTest
detection still blocks live services, but those configurations share the normal
app's AppKit preferences domain. The host-isolation regression test rejects that
configuration.

## Adding tests

- Exercise launcher transitions through `ApplicationLauncher`, injecting a
  `PreferencesStore` and a service factory. `IsolatedPreferences` owns a unique
  defaults suite and removes it when released. Keep fixture references alive for
  the duration of the test.
- Exercise services directly with in-memory databases, temporary audio/Serato
  directories, and controlled lifecycle sources. Do not construct live
  `AppServices`; its initializer rejects XCTest before starting any work.
- `LibraryDatabase.openDefault()`, `SeratoLibraryLocator.defaultLocation()`, and
  `PreferencesStore.live()` also reject XCTest before accessing production
  resources. `UserPreferences` is the production facade; use an injected store
  in tests. Never clear or restore the user's standard preferences as test setup.
- Stop any fixture-owned workers/watchers and await their completion before
  deleting temporary files. The host itself starts none.

This is an application startup boundary, not an operating-system sandbox. Tests
that bypass these factories and explicitly open arbitrary paths still need
isolated fixtures. A green suite alone is not evidence that new test code respects
that contract.


## Paged Library fixture

`LibraryPagingTests` creates one temporary WAL database with 30,000 synthetic
files. It never opens the owner's library or creates audio. Run it in the isolated
Test host:

```sh
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Test \
  -derivedDataPath build-output/DerivedData \
  -only-testing:CrateAgentTests/LibraryPagingTests test
```

The `PAGED_LIBRARY_METRICS` log and XCTest attachment report Library rendering
inside an existing window, distant scrollbar work, initial/distant asynchronous
load latency, maximum main-actor heartbeat delay, decoded row totals, and peak
cached rows. Rendering and scroll gestures run in separate main-actor turns,
with a short idle interval between interactions. OS window setup is reported separately. Targets are below 100 ms for
rendering and below 50 ms for main-thread work; timings are measured evidence,
not machine-dependent pass/fail thresholds. The normal cache bound is 1,000 rows
(200 per page, five pages); oversized viewports declare a larger effective page
size while retaining the five-page bound. Memory and identity assertions are
hard requirements. Generic controller tests cover controlled stale completions
and error/retry races, and native table tests cover deferred selection and context
IDs independently of Library's row type.
