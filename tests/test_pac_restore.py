"""Run the production recovery methods with an isolated preferences suite and fake helper.

No system network settings or real app preferences are changed. Requires Swift.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'WLocApp/WLocAppMac/AppWLocPACManager.swift').read_text()
start = source.index('    private func loadSavedSettings()')
end = source.index('    private func ensureHelper()', start)
methods = source[start:end].replace('UserDefaults.standard', 'defaults')
harness = r'''
import Foundation
struct AppWLocPACNetworkSetting { let service: String; let url: String?; let enabled: Bool }
enum AppWLocPACError: Error { case commandFailed(String) }
final class RecoveryHarness {
    struct SavedPACSetting: Codable { let url: String?; let enabled: Bool }
    let defaults: UserDefaults
    let savedSettingsKey = "backup"
    var previousSettings: [String: SavedPACSetting] = [:]
    var failures: Set<String> = []
    var calls: [String] = []
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func setPAC(_ settings: [AppWLocPACNetworkSetting]) throws {
        for setting in settings {
            calls.append(setting.service)
            if failures.contains(setting.service) { throw AppWLocPACError.commandFailed("unavailable") }
        }
    }
    func recover() throws -> Error? {
        try loadSavedSettings()
        return restorePAC(previousSettings)
    }
'''
harness += methods + '\n}\n'
harness += r'''
let suite = "wloc.restore.tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = [
    "Wi-Fi": RecoveryHarness.SavedPACSetting(url: "https://example.invalid/original.pac", enabled: true),
    "Ethernet": RecoveryHarness.SavedPACSetting(url: nil, enabled: false)
]
let original = try JSONEncoder().encode(settings)
defaults.set(original, forKey: "backup")
let first = RecoveryHarness(defaults)
first.failures = ["Ethernet"]
assert(try first.recover() != nil)
let pending = try JSONDecoder().decode([String: RecoveryHarness.SavedPACSetting].self, from: defaults.data(forKey: "backup")!)
assert(Set(pending.keys) == ["Ethernet"])
assert(pending["Ethernet"]!.enabled == false)
assert(pending["Ethernet"]!.url == nil)
first.calls = []
first.failures = []
assert(try first.recover() == nil)
assert(first.calls == ["Ethernet"])
assert(defaults.data(forKey: "backup") == nil)
first.calls = []
assert(try first.recover() == nil)
assert(first.calls.isEmpty)
print("PASS: partial failure, retry only pending services, repeated restore")

defaults.set(original, forKey: "backup")
let failed = RecoveryHarness(defaults)
failed.failures = ["Wi-Fi", "Ethernet"]
assert(try failed.recover() != nil)
let restarted = RecoveryHarness(defaults)
assert(try restarted.recover() == nil)
assert(Set(restarted.calls) == Set(settings.keys))
assert(defaults.data(forKey: "backup") == nil)
print("PASS: failed recovery survives app restart")

defaults.set(Data("broken".utf8), forKey: "backup")
let corrupt = RecoveryHarness(defaults)
do {
    _ = try corrupt.recover()
    fatalError("Corrupt backup must fail")
} catch {
    assert(defaults.data(forKey: "backup") == Data("broken".utf8))
    assert(corrupt.calls.isEmpty)
}
print("PASS: corrupt backup is preserved and never applied")
'''
# Swift assert uses a nonthrowing autoclosure.
harness = harness.replace('assert(try ', 'assertValue(try ')
harness += '\nfunc assertValue(_ value: Bool) { assert(value) }\n'
with tempfile.TemporaryDirectory(prefix='wloc-restore-tests-') as folder:
    test = Path(folder) / 'main.swift'
    test.write_text(harness)
    subprocess.run(['swift', str(test)], check=True)
