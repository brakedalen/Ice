//
//  SectionLayoutEditing27.swift
//  Ice
//

extension SectionLayout27 {
    /// Adapts per-item automation to app-wide sections. Only apps with a live
    /// matching rule/restore are changed; their ungoverned siblings keep their
    /// current section, with the most visible section winning any conflict.
    static func automationSections(
        items: [(bundleID: String, key: String, section: MacOS27Section)],
        desired: [String: MacOS27Section]
    ) -> [String: MacOS27Section] {
        let affectedBundles = Set(items.compactMap { desired[$0.key] == nil ? nil : $0.bundleID })
        return appSections(items: items.compactMap { item in
            guard affectedBundles.contains(item.bundleID) else { return nil }
            return (item.bundleID, desired[item.key] ?? item.section)
        })
    }

    /// The saved layout after moving an application to a section. Applications missing
    /// from the layout are visible, so moving one to Visible removes its entry.
    static func settingSection(_ section: MacOS27Section, for bundleID: String, in saved: [String: MacOS27Section]) -> [String: MacOS27Section] {
        var updated = saved
        updated[bundleID] = section == .visible ? nil : section
        return updated
    }
}
