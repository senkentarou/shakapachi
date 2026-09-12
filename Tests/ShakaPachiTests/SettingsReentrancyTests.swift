// SettingsReentrancyTests.swift
// Regression test for the exclusive-access (SIGABRT) crash that happened when a
// synchronous .settingsDidChange observer read the SAME Settings property while
// that property's wrapper setter was still on the stack (as Settings' own
// objectWillChange bridge does when a SwiftUI binding writes Settings). The
// `nonmutating set` on the Defaults*
// wrappers fixes it: writing to `defaults` no longer requires exclusive access to
// the wrapper, so the concurrent read is a harmless shared read. Before the fix
// the `settings.xxx = ...` lines below aborted the process — "not crashing" IS
// the assertion here.

import XCTest

@testable import ShakaPachi

@MainActor
final class SettingsReentrancyTests: XCTestCase {

    private func makeSuite(name: String = #function) -> (UserDefaults, Settings) {
        let suiteName = "com.shakapachi.tests.SettingsReentrancyTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, settings)
    }

    // Enum wrapper (DefaultsEnum) — the path the crash report showed.
    func testSynchronousObserverReadingEnumPropertyDoesNotCrash() {
        let (_, settings) = makeSuite()
        var observed: TriggerModifier?

        // queue: nil → the observer runs synchronously on the posting thread,
        // reproducing the in-stack read that used to crash.
        let token = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: nil
        ) { [weak settings] _ in
            MainActor.assumeIsolated {
                observed = settings?.triggerModifier
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.triggerModifier = .option  // would SIGABRT before the fix

        XCTAssertEqual(settings.triggerModifier, .option)
        XCTAssertEqual(
            observed, .option,
            "the synchronous observer must see the freshly-set value")
    }

    // Int wrapper (DefaultsInt) — lock the fix across wrapper kinds.
    func testSynchronousObserverReadingIntPropertyDoesNotCrash() {
        let (_, settings) = makeSuite()
        var observed: Int?

        let token = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: nil
        ) { [weak settings] _ in
            MainActor.assumeIsolated {
                observed = settings?.showDelayMs
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.showDelayMs = 123

        XCTAssertEqual(settings.showDelayMs, 123)
        XCTAssertEqual(observed, 123)
    }
}
