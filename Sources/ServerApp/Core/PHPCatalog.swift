// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Every PHP version Server can use, with its support status.
///
/// Homebrew's main repository only carries current PHP versions. Older ones (5.6, 7.x, 8.0) come
/// from the community tap `shivammathur/php`, which publishes ready-made packages of maintained
/// backports. Server only adds that tap when you confirm installing one of those versions.
enum PHPCatalog {
    static let tap = "shivammathur/php"

    /// Newest first. "php" is whatever Homebrew currently calls the latest release.
    static let formulae = ["php", "php@8.5", "php@8.4", "php@8.3", "php@8.2", "php@8.1",
                           "php@8.0", "php@7.4", "php@7.3", "php@7.2", "php@7.1", "php@7.0", "php@5.6"]

    /// Versions Homebrew's main repository no longer has: installed from the community tap.
    static let tapFormulae: Set<String> = ["php@8.0", "php@7.4", "php@7.3", "php@7.2", "php@7.1", "php@7.0", "php@5.6"]

    /// Last day of security fixes per release series (php.net/supported-versions.php; older
    /// dates match the tap's own deprecation dates).
    private static let securityEnd: [String: String] = [
        "5.6": "2018-12-31", "7.0": "2019-01-10", "7.1": "2019-12-01", "7.2": "2020-11-30", "7.3": "2021-12-06",
        "7.4": "2022-11-28", "8.0": "2023-11-26", "8.1": "2025-12-31", "8.2": "2026-12-31", "8.3": "2027-12-31",
        "8.4": "2028-12-31", "8.5": "2029-12-31", "8.6": "2030-12-31",
    ]

    /// What `brew install` is given for this formula.
    static func installName(_ formula: String) -> String {
        tapFormulae.contains(formula) ? "\(tap)/\(formula)" : formula
    }

    static func needsTap(_ formula: String) -> Bool { tapFormulae.contains(formula) }

    /// "8.3" for php@8.3; for the latest `php`, the series of the installed version.
    static func series(_ formula: String, version: String?) -> String? {
        if formula.hasPrefix("php@") { return String(formula.dropFirst(4)) }
        return version.map(Homebrew.shortVersion)
    }

    static func securityEndDate(_ formula: String, version: String?) -> Date? {
        guard let s = series(formula, version: version), let text = securityEnd[s] else { return nil }
        // Local noon, so the date reads the same in every time zone.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text + " 12:00")
    }

    enum Status: Equatable {
        case supported
        case endingSoon(Date)          // security fixes stop within 4 months
        case endOfLife(Date)
    }

    static func status(_ formula: String, version: String?, now: Date = Date()) -> Status {
        guard let end = securityEndDate(formula, version: version) else { return .supported }
        if end < now { return .endOfLife(end) }
        if end < now.addingTimeInterval(120 * 86_400) { return .endingSoon(end) }
        return .supported
    }

    static func isEndOfLife(_ formula: String, version: String?) -> Bool {
        if case .endOfLife = status(formula, version: version) { return true }
        return false
    }

    /// PHP older than 7.2.5 can't run current Composer.
    static func isTooOldForComposer(_ formula: String) -> Bool {
        guard let s = series(formula, version: nil), let v = Double(s) else { return false }
        return v < 7.2
    }

    private static func long(_ date: Date) -> String { date.formatted(date: .long, time: .omitted) }

    /// A warning for versions that are out of security support (or about to be), else nil.
    static func warning(_ formula: String, version: String?) -> String? {
        let name = "PHP " + (series(formula, version: version) ?? "")
        switch status(formula, version: version) {
        case .supported: return nil
        case .endingSoon(let d):
            return "Security support for \(name) ends on \(long(d)). After that it gets no more security fixes."
        case .endOfLife(let d):
            return "\(name) reached end of life on \(long(d)) and no longer gets security fixes from PHP. "
                + "Use it only for legacy applications that need it, and don't expose those sites to the internet."
        }
    }

    /// Supported versions first, then end-of-life ones (both newest first).
    static func grouped(version: (String) -> String?) -> (supported: [String], endOfLife: [String]) {
        var supported: [String] = [], eol: [String] = []
        for f in formulae { (isEndOfLife(f, version: version(f)) ? { eol.append(f) } : { supported.append(f) })() }
        return (supported, eol)
    }
}
