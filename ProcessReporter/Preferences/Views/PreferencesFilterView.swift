//
//  PreferencesFilterView.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/13.
//

import AppKit
import RxCocoa
import RxSwift
import SwiftUI
import UniformTypeIdentifiers

struct AppItem: Identifiable {
    let id = UUID()
    let applicationIdentifier: String
    let name: String
    let icon: Image
}

struct ApplicationTableView: View {
    @Binding var appItems: [AppItem]
    @State private var selectedProcessItems = Set<UUID>()
    @State private var isTargeted: Bool = false
    @State private var showingAppPicker = false

    var title: String
    var description: String
    var onSave: ((_ items: [AppItem]) -> Void)?

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)

            Text(
                description
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(2)

            Table(appItems, selection: $selectedProcessItems) {
                TableColumn("Application") { item in
                    HStack(spacing: 8) {
                        item.icon
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                        Text(item.name)
                    }
                }
            }

            .tableColumnHeaders(.hidden)
            .tableStyle(BorderedTableStyle())
            .clipShape(RoundedRectangle(cornerRadius: 8).inset(by: 1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .padding(.top, 8)
            .frame(minHeight: 200)
            .overlay(
                Group {
                    if appItems.isEmpty {
                        Text("Drag and drop applications here to filter them")
                            .foregroundColor(.secondary)
                    }
                }
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            .contextMenu(forSelectionType: UUID.self) { items in
                if let selectedItem = items.first,
                   let item = appItems.first(where: { $0.id == selectedItem })
                {
                    let showOpenInFinder = selectedProcessItems.count <= 1

                    if showOpenInFinder {
                        Button("Show in Finder") {
                            showInFinder(applicationIdentifier: item.applicationIdentifier)
                        }

                        Divider()
                    }

                    Button("Remove") {
                        removeApp(id: item.id)
                    }
                }
            }
            // TODO: add backspace
            .onKeyPress(.deleteForward, action: handleKeyDelete)
            #if DEBUG
                .onReceive(
                    selectedProcessItems.publisher,
                    perform: { value in
                        debugPrint(value)
                    }
                )
            #endif

            // Button group below the table
            HStack {
                Spacer()
                HStack {
                    Button(action: {
                        showingAppPicker = true
                    }) {
                        Image(systemName: "plus").bold()
                    }
                    .accessibilityLabel("Add application")
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)

                    Rectangle().frame(width: 1, height: 16)
                        .foregroundColor(Color(NSColor.separatorColor))

                    Button(action: {
                        removeSelectedApps()
                    }) {
                        Image(systemName: "minus").bold()
                    }
                    .accessibilityLabel("Remove selected applications")
                    .buttonStyle(.plain)
                    .disabled(selectedProcessItems.isEmpty)
                    .frame(width: 16, height: 16)
                }
                .padding(4)
            }
            // App Picker sheet
            .sheet(isPresented: $showingAppPicker) {
                AppPickerView { appId, url in
                    if let appId = appId, let url = url {
                        addApp(appId: appId, url: url)
                    }
                    showingAppPicker = false
                }
                .frame(width: 600, height: 400)
            }
        }
        .padding()
    }

    private func removeApp(id: UUID) {
        if selectedProcessItems.isEmpty {
            appItems.removeAll { $0.id == id }
        } else {
            appItems.removeAll { item in
                selectedProcessItems.contains(item.id)
            }
        }
        withAnimation {
            selectedProcessItems.removeAll()
        }
        saveFilteredApps()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url = url, error == nil else { return }

                // Check if it's an application
                if url.pathExtension == "app" {
                    DispatchQueue.main.async {
                        if let bundle = Bundle(url: url),
                           let appId = bundle.bundleIdentifier
                        {
                            addApp(appId: appId, url: url)
                        }
                    }
                }
            }
        }
        return true
    }

    private func addApp(appId: String, url: URL) {
        // Get app icon
        let workspace = NSWorkspace.shared
        let nsImage = workspace.icon(forFile: url.path)
        let image = Image(nsImage: nsImage)

        // Check if app already exists in the list
        if !appItems.contains(where: { $0.applicationIdentifier == appId }) {
            let appName = url.deletingPathExtension().lastPathComponent
            appItems.append(AppItem(applicationIdentifier: appId, name: appName, icon: image))
            saveFilteredApps()
        }
    }

    private func saveFilteredApps() {
        onSave?(appItems)
    }

    // Handle keyboard delete/backspace key press
    private func handleKeyDelete() -> KeyPress.Result {
        // Only proceed if items are selected
        if !selectedProcessItems.isEmpty {
            removeSelectedApps()
            return .handled
        }
        return .ignored
    }

    private func removeSelectedApps() {
        appItems.removeAll { item in
            selectedProcessItems.contains(item.id)
        }
        saveFilteredApps()
        withAnimation {
            selectedProcessItems.removeAll()
        }
    }

    private func showInFinder(applicationIdentifier: String) {
        guard let appURL = AppUtility.shared.getAppInfo(for: applicationIdentifier).path else {
            ToastManager.shared.error("Cannot find app")
            return
        }
        NSWorkspace.shared.selectFile(appURL.path, inFileViewerRootedAtPath: "")
    }
}

struct PreferencesFilterView: View {
    @State private var appItems: [AppItem] = []
    @State private var mediaItems: [AppItem] = []

    @State private var tabId: String = "app"
    var body: some View {
        TabView(selection: $tabId) {
            Tab("Applications", systemImage: "app", value: "app") {
                ApplicationTableView(
                    appItems: $appItems,
                    title: "Filter Applications",
                    description:
                    "Add applications that should be filtered from reporting. Drag applications from Finder to add them."
                ) { items in
                    PreferencesDataModel.filteredProcesses.accept(
                        items.map { $0.applicationIdentifier })
                }
            }

            Tab("Media Process", systemImage: "app", value: "media") {
                ApplicationTableView(
                    appItems: $mediaItems,
                    title: "Filter Media Processes",
                    description:
                    "Reports of the following media applications are ignored. Drag applications from Finder to add them."
                ) { items in
                    PreferencesDataModel.filteredMediaProcesses.accept(
                        items.map { $0.applicationIdentifier })
                }
            }
        }
        .onAppear {
            loadSavedApps()
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSavedApps() {
        func loadAppItems(from appIds: [String]) -> [AppItem] {
            appIds.map { appId in
                let appInfo = AppUtility.shared.getAppInfo(for: appId)
                return AppItem(
                    applicationIdentifier: appId,
                    name: appInfo.displayName,
                    icon: Image(nsImage: appInfo.icon)
                )
            }
        }

        appItems = loadAppItems(from: PreferencesDataModel.filteredProcesses.value)
        mediaItems = loadAppItems(from: PreferencesDataModel.filteredMediaProcesses.value)
    }
}

#Preview {
    PreferencesFilterView()
}

class PreferencesHostingController: NSHostingController<PreferencesFilterView> {
    convenience init() {
        self.init(rootView: PreferencesFilterView())
    }
}
