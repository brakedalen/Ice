//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(spacing: 20) {
                header
                layoutBars
                spacersSection
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        IceSection {
            VStack(spacing: 3) {
                Text("Drag to arrange your menu bar items into different sections.")
                    .font(.title3.bold())
                Text("Items can also be arranged by ⌘ Command + dragging them in the menu bar.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 20) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
        .opacity(hasItems ? 1 : 0.75)
        .blur(radius: hasItems ? 0 : 5)
        .allowsHitTesting(hasItems)
        .overlay {
            if !hasItems {
                loadingMenuBarItems
            }
        }
    }

    @ViewBuilder
    private var spacersSection: some View {
        IceSection("Spacers") {
            MenuBarSpacersSection(settings: appState.settings.general)
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Ice cannot arrange menu bar items in automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermissions: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)

            Text("On macOS 26, Ice may need to relaunch after you grant this permission.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                } label: {
                    Text("Go to Advanced Settings")
                }
                .buttonStyle(.link)

                Button("Relaunch Ice") {
                    appState.relaunch()
                }
            }
        }
    }

    @ViewBuilder
    private var loadingMenuBarItems: some View {
        VStack {
            Text("Loading menu bar items…")
            ProgressView()
        }
        .font(.title)
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading) {
                Text(name.localized)
                    .font(.headline)
                    .padding(.leading, 8)

                LayoutBar(imageCache: appState.imageCache, section: name)
            }
        }
    }
}


// MARK: - MenuBarSpacersSection

private struct MenuBarSpacersSection: View {
    @ObservedObject var settings: GeneralSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spacers add empty space between menu bar items, letting you group them visually. New spacers appear in the visible section — drag them into position above, or ⌘ Command + drag them in the menu bar.")
                .foregroundStyle(.secondary)

            ForEach($settings.menuBarSpacers) { $spacer in
                HStack {
                    Image(systemName: "arrow.left.and.right.square")
                    IcePicker("Width", selection: $spacer.width) {
                        ForEach([12, 16, 24, 32, 48, 64], id: \.self) { width in
                            Text("\(width) px").tag(width)
                        }
                    }
                    .frame(maxWidth: 150)

                    Spacer()

                    Button {
                        settings.menuBarSpacers.removeAll { $0.id == spacer.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this spacer")
                }
            }

            Button("Add Spacer") {
                settings.menuBarSpacers.append(GeneralSettings.MenuBarSpacer())
            }
            .disabled(settings.menuBarSpacers.count >= 10)

            Toggle("Show spacer markers", isOn: $settings.showSpacerMarkers)
        }
    }
}
