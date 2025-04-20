//
//  PreferencesMappingViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/21.
//
import AppKit
import SnapKit
import SwiftUI

class PreferencesMappingViewController: NSViewController, SettingWindowProtocol {
	let frameSize: NSSize = .init(width: 600, height: 400)

	convenience init() {
		self.init(nibName: nil, bundle: nil)
	}

	override func loadView() {
		view = NSHostingView(rootView: MappingView())
	}

	override func viewWillAppear() {}
}

struct MappingView: View {
	var body: some View {
		VStack {
			HStack {
				VStack(alignment: .leading) {
					Text("Mapping").font(.headline)
						.padding(.bottom, 6)

					Text("Setting the rewrite rules for the display name when a process is reported.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}.padding()
				Spacer()
			}

			List {
				// TODO:
			}.frame(maxHeight: .infinity)
				.listStyle(.inset)

			HStack {
				Spacer().frame(maxWidth: .infinity)
				Button {} label: {
					Image(systemName: "plus").font(Font.system(size: 12, weight: .bold))
				}.padding(.trailing, 3).buttonStyle(.plain)

				Rectangle().fill(.separator).frame(width: 1, height: 16).clipShape(RoundedRectangle(cornerRadius: 4))

				Button {} label: {
					Image(systemName: "minus").font(Font.system(size: 12, weight: .regular))
				}.padding(.leading, 3).padding(.trailing, 12)
					.buttonStyle(.plain)
			}.padding(.bottom, 12).padding(.top, 6)
		}
	}
}
