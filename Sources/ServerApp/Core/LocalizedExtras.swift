// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Texts that are looked up by name at run time (tab titles come from enum raw values), listed here
/// so the localization check finds them. Never used at run time.
enum LocalizedExtras {
    static let tabs: [LocalizedStringResource] = [
        "Overview", "Try It", "Settings", "Records", "Users", "Extensions", "Composer", "Storage", "Components",
        "Console", "Modules", "Databases", "General", "Share", "SSL", "All Content", "iCloud Content", "Shared Content",
    ]
}
