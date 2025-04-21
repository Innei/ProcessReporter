//
//  PreferencesMappingViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/21.
//
import AppKit
import RxCocoa
import RxSwift
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

class MappingViewModel: ObservableObject {
	@Published var data: [PreferencesDataModel.Mapping] = []
	private let disposeBag = DisposeBag()

	init() {
		// 订阅 PreferencesDataModel 的 mappingList
		PreferencesDataModel.shared.mappingList
			.subscribe(onNext: { [weak self] items in
				self?.data = items.getList()
			})
			.disposed(by: disposeBag)
	}
}

struct MappingView: View {
	@StateObject private var viewModel = MappingViewModel()
	@State var selectedItem: Set<String> = []

	@State var addNewItemSheetOpen = false
	@State var editingItem: PreferencesDataModel.Mapping? = nil
	@State var editingIndex: Int? = nil

	var body: some View {
		VStack {
			HStack {
				VStack(alignment: .leading) {
					Text("Mapping").font(.headline)
						.padding(.bottom, 4)

					Text("Setting the rewrite rules for the display name when a process is reported.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}.padding()
				Spacer()
			}

			Table(viewModel.data, selection: $selectedItem) {
				TableColumn("type") { item in
					Text(item.type.toCopyable())
						.lineLimit(1)
				}.width(min: 150)

				TableColumn("from") { item in
					Text(item.from)
						.lineLimit(1)
				}
				TableColumn("to") { item in
					Text(item.to)
						.lineLimit(1)
				}
			}.frame(maxHeight: .infinity)
				.tableStyle(.inset)
				.contextMenu(forSelectionType: PreferencesDataModel.Mapping.ID.self) { selection in
					Button("Edit") {
						if let id = selection.first, let item = viewModel.data.first(where: { $0.id == id }) {
							editingItem = item
							editingIndex = viewModel.data.firstIndex(where: { $0.id == id })
						}
					}
					Divider()
					Button("Delete", role: .destructive) {
						PreferencesDataModel.shared.mappingList.value.removeMapping(viewModel.data.filter { selection.contains($0.id) })
					}
				} primaryAction: { _ in
					if selectedItem.count == 1, let id = selectedItem.first, let itemIndex = viewModel.data.firstIndex(where: { $0.id == id }) {
						let item = viewModel.data[itemIndex]
						editingItem = item
						editingIndex = itemIndex
					}
				}

			HStack {
				Spacer().frame(maxWidth: .infinity)
				Button {
					addNewItemSheetOpen.toggle()
				} label: {
					Image(systemName: "plus").font(Font.system(size: 12, weight: .bold))
				}.padding(.trailing, 3).buttonStyle(.plain)

				Rectangle().fill(.separator).frame(width: 1, height: 16).clipShape(RoundedRectangle(cornerRadius: 4))

				Button {
					withAnimation {
						PreferencesDataModel.shared.mappingList.value.removeMapping(viewModel.data.filter { selectedItem.contains($0.id) })
					}

				} label: {
					Image(systemName: "minus").font(Font.system(size: 12, weight: .regular))
				}.padding(.leading, 3).padding(.trailing, 12)
					.buttonStyle(.plain)
			}.padding(.bottom, 12).padding(.top, 6)
		}.sheet(isPresented: $addNewItemSheetOpen) {
			withAnimation {
				AddNewMappingView(mode: .add, onComplete: { from, to, type in
					PreferencesDataModel.shared.mappingList.value.addMapping(.init(type: type, from: from, to: to))
				})
			}
		}
		.sheet(item: $editingItem) { item in
			AddNewMappingView(mode: .edit(item), onComplete: { from, to, type in
				PreferencesDataModel.shared.mappingList.value.editMapping(.init(type: type, from: from, to: to), for: editingIndex!)
			})
		}
	}
}

struct AddNewMappingView: View {
	enum Mode: Identifiable, Equatable {
		static func == (lhs: AddNewMappingView.Mode, rhs: AddNewMappingView.Mode) -> Bool {
			switch (lhs, rhs) {
			case (.add, .add): return true
			case (.edit(let lhsMapping), .edit(let rhsMapping)): return lhsMapping == rhsMapping
			default: return false
			}
		}

		case add
		case edit(PreferencesDataModel.Mapping)
		var id: String {
			switch self {
			case .add: return "add"
			case .edit(let mapping): return "edit-" + mapping.id
			}
		}
	}

	@State var from: String = ""
	@State var to: String = ""
	@State var type: PreferencesDataModel.MappingType = .processApplicationIdentifier

	var mode: Mode = .add
	typealias OnCompleteCallback = (_ from: String, _ to: String, _ type: PreferencesDataModel.MappingType) -> Void
	var onComplete: OnCompleteCallback

	@Environment(\.presentationMode) private var presentationMode

	init(mode: Mode = .add, onComplete: @escaping OnCompleteCallback) {
		self.mode = mode
		self.onComplete = onComplete
		switch mode {
		case .add:
			break
		case .edit(let mapping):
			_from = State(initialValue: mapping.from)
			_to = State(initialValue: mapping.to)
			_type = State(initialValue: mapping.type)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Text(mode == Mode.add ? "Add New Mapping" : "Edit Mapping")
				.font(.title2)
				.bold()
				.padding(.bottom, 8)

			Grid(horizontalSpacing: 16, verticalSpacing: 12) {
				GridRow {
					Text("From")
						.frame(width: 70, alignment: .trailing)
					TextField("Enter the original name", text: $from)
						.textFieldStyle(RoundedBorderTextFieldStyle())
						.frame(minWidth: 200)
				}
				GridRow {
					Text("Filter Type")
						.frame(width: 70, alignment: .trailing)
					Picker("", selection: $type) {
						ForEach(PreferencesDataModel.MappingType.allCases, id: \.self) { type in
							Text(type.toCopyable()).tag(type)
						}
					}
					.pickerStyle(.menu)
					.frame(minWidth: 200)
				}
				GridRow {
					Text("Target Name")
						.frame(width: 70, alignment: .trailing)
					TextField("Enter target process name", text: $to)
						.textFieldStyle(RoundedBorderTextFieldStyle())
						.frame(minWidth: 200)
				}
			}
			.padding(.horizontal, 8)

			HStack {
				Spacer()
				Button("Cancel") {
					presentationMode.wrappedValue.dismiss()
				}
				.keyboardShortcut(.cancelAction)
				.buttonStyle(.bordered)

				Button("Done") {
					onComplete(from, to, type)
					presentationMode.wrappedValue.dismiss()
				}
				.keyboardShortcut(.defaultAction)
				.buttonStyle(.borderedProminent)
				.disabled(from.isEmpty || to.isEmpty)
			}
			.padding(.top, 8)
		}
		.padding(24)
		.frame(width: 380)
	}
}
