//
//  AppPickerView.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/13.
//
import SwiftUI

// Add AppPickerView to show a dialog for selecting applications
struct AppPickerView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var installedApps: [InstalledApp] = []
	@State private var searchText: String = ""
	@State private var isLoading = true

	var onSelectApp: (String?, URL?) -> Void

	var body: some View {
		VStack {
			TextField("Search applications", text: $searchText)
				.textFieldStyle(.roundedBorder)
				.padding()

			List {
				if isLoading {
					HStack {
						Spacer()
						ProgressView("Finding applications…")
						Spacer()
					}
				}

				ForEach(filteredApps) { app in
					Button(action: {
						onSelectApp(app.applicationIdentifier, app.url)
						dismiss()
					}) {
						HStack {
							Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
								.resizable()
								.frame(width: 24, height: 24)
							Text(app.name)
							Spacer()
						}
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
			}

			HStack {
				Spacer()
				Button("Cancel") {
					onSelectApp(nil, nil)
					dismiss()
				}
				.keyboardShortcut(.cancelAction)
			}
			.padding()
		}
		.task {
			isLoading = true
			installedApps = await Self.discoverInstalledApps()
			isLoading = false
		}
	}

	private struct InstalledApp: Identifiable, Sendable {
		var id: String { applicationIdentifier }
		let name: String
		let url: URL
		let applicationIdentifier: String
	}

	private var filteredApps: [InstalledApp] {
		if searchText.isEmpty {
			return installedApps
		} else {
			return installedApps.filter { app in
				app.name.localizedCaseInsensitiveContains(searchText)
					|| app.applicationIdentifier.localizedCaseInsensitiveContains(searchText)
			}
		}
	}

	private static func discoverInstalledApps() async -> [InstalledApp] {
		await Task.detached(priority: .userInitiated) {
			let fileManager = FileManager()
			let roots = [
				fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
				URL(fileURLWithPath: "/Applications", isDirectory: true),
				URL(fileURLWithPath: "/System/Applications", isDirectory: true),
			]
			var applicationsByIdentifier: [String: InstalledApp] = [:]

			for root in roots where fileManager.fileExists(atPath: root.path) {
				guard let enumerator = fileManager.enumerator(
					at: root,
					includingPropertiesForKeys: [.isApplicationKey, .isPackageKey],
					options: [.skipsHiddenFiles, .skipsPackageDescendants]
				) else { continue }

				while let url = enumerator.nextObject() as? URL {
					guard url.pathExtension.lowercased() == "app" else { continue }
					enumerator.skipDescendants()
					guard let bundle = Bundle(url: url),
					      let applicationIdentifier = bundle.bundleIdentifier,
					      applicationsByIdentifier[applicationIdentifier] == nil
					else { continue }

					let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
						?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
						?? url.deletingPathExtension().lastPathComponent
					applicationsByIdentifier[applicationIdentifier] = InstalledApp(
						name: name,
						url: url,
						applicationIdentifier: applicationIdentifier)
				}
			}

			return applicationsByIdentifier.values.sorted {
				$0.name.localizedStandardCompare($1.name) == .orderedAscending
			}
		}.value
	}
}

extension AppPickerView {
	static func showAppPicker(for anchorView: NSView, completion: @escaping (String?, URL?) -> Void) {
		let popover = NSPopover()
		let appPicker = AppPickerView { [weak popover] applicationIdentifier, url in
			completion(applicationIdentifier, url)
			popover?.performClose(nil)
		}
		let hostingController = NSHostingController(rootView: appPicker)

		popover.contentViewController = hostingController
		popover.behavior = .transient
		popover.contentSize = NSSize(width: 400, height: 500)
		popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
	}
}
