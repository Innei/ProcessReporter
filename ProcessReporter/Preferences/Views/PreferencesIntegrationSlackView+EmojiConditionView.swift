import AppKit
import SnapKit
import UniformTypeIdentifiers

extension PreferencesIntegrationSlackView {
	@MainActor
	class EmojiConditionViewController: NSViewController {
		// MARK: - Properties

		private var conditions: [EmojiConditionList.EmojiCondition] = []
		private var itemViews: [ConditionFormItemView] = []
		private var draggedView: ConditionFormItemView?
		private var draggedIndex: Int?
		private var dropIndicatorView: NSView?
		private var eventMonitor: Any?
		private var draggedCloneView: NSView?
		private var dragOffset: CGFloat = 0

		// MARK: - UI Components

		private lazy var titleLabel: NSTextField = {
			let label = NSTextField(labelWithString: "Conditions")
			label.font = NSFont.boldSystemFont(ofSize: 16)
			return label
		}()

		private lazy var scrollView: NSScrollView = {
			let scrollView = NSScrollView()
			scrollView.hasVerticalScroller = true
			scrollView.borderType = .noBorder
			scrollView.autohidesScrollers = true
			return scrollView
		}()

		private lazy var contentView: NSView = {
			let view = NSView()
			return view
		}()

		private lazy var buttonStack: NSStackView = {
			let stackView = NSStackView()
			stackView.spacing = 8
			stackView.orientation = .horizontal
			stackView.distribution = .equalCentering
			return stackView
		}()

		private lazy var closeModalButton: NSButton = {
			let button = NSButton(title: "Close", target: self, action: #selector(cancel))
			button.bezelStyle = .rounded
			button.keyEquivalent = "\u{1b}"
			return button
		}()

		private lazy var saveButton: NSButton = {
			let button = NSButton(title: "Save", target: self, action: #selector(save))
			button.bezelStyle = .push
			button.keyEquivalent = "\r"
			return button
		}()

		private lazy var addButton: NSButton = {
			let button = NSButton(title: "Add Condition", target: self, action: #selector(addCondition))
			button.bezelStyle = .rounded
			return button
		}()

		// MARK: - View Lifecycle

		override func loadView() {
			view = NSView(frame: NSRect(origin: .zero, size: .init(width: 600, height: 500)))

			// Set title for window
			title = "Emoji Conditions"

			setupUI()
		}

		override func viewDidLoad() {
			super.viewDidLoad()
		}

		override func viewDidAppear() {
			super.viewDidAppear()
			// Load existing conditions
			loadExistingConditions()
		}

		override func viewWillDisappear() {
			super.viewWillDisappear()
			cleanUpDragState()
		}

		private func loadExistingConditions() {
			conditions = PreferencesDataModel.shared.slackIntegration.value.customEmojiConditionList.getConditions()
			updateItems()
		}

		private func updateItems() {
			// 先清除已有的子视图
			for subview in contentView.subviews {
				subview.removeFromSuperview()
			}

			// Reset stored item views
			itemViews.removeAll()
			dropIndicatorView = nil
			draggedCloneView = nil

			var previousItem: ConditionFormItemView?
			for (index, condition) in conditions.enumerated() {
				let itemView = ConditionFormItemView(initialValue: condition)
				configure(itemView, at: index)
				contentView.addSubview(itemView)
				itemViews.append(itemView)

				itemView.snp.makeConstraints { make in
					make.horizontalEdges.equalToSuperview()

					if let previousItem = previousItem {
						make.top.equalTo(previousItem.snp.bottom).offset(16)
					} else {
						make.top.equalToSuperview()
					}
				}
				itemView.sizeToFit()
				previousItem = itemView
			}

			layout()
		}

		private func configure(_ itemView: ConditionFormItemView, at index: Int) {
			itemView.index = index
			itemView.onDelete = { [weak self] in
				self?.removeCondition(at: index)
			}
			itemView.onDragStart = { [weak self] view in
				self?.handleDragStart(view)
			}
			itemView.onDragEnded = { [weak self] view in
				self?.handleDragEnd(view)
			}
		}

		private func snapshotCurrentConditions() {
			conditions = itemViews.map { $0.saveCondition() }
		}

		private func handleDragStart(_ view: ConditionFormItemView) {
			draggedView = view
			draggedIndex = view.index

			// Calculate drag offset
			let localPoint = view.convert(NSEvent.mouseLocation, from: nil)
			dragOffset = localPoint.y

			// Create a clone/snapshot of the view for dragging
			let cloneView = NSImageView()
			cloneView.image = view.snapshot()
			cloneView.frame = view.frame
			cloneView.alphaValue = 0.9
			cloneView.wantsLayer = true
			cloneView.layer?.shadowOpacity = 0.8
			cloneView.layer?.shadowRadius = 8
			cloneView.layer?.shadowOffset = CGSize(width: 0, height: 2)
			contentView.addSubview(cloneView)
			draggedCloneView = cloneView

			// Semi-hide the original
			view.alphaValue = 0.3

			// Create drop indicator view if needed
			if dropIndicatorView == nil {
				let indicator = NSView()
				indicator.wantsLayer = true
				indicator.layer?.backgroundColor = NSColor.selectedControlColor.cgColor
				indicator.layer?.cornerRadius = 2
				contentView.addSubview(indicator)
				dropIndicatorView = indicator
				indicator.isHidden = true
			}

			// Start tracking mouse events for dragging
			eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
				self?.handleMouseDrag(with: event)
				return event
			}
		}

		private func handleMouseDrag(with event: NSEvent) {
			guard let draggedView = draggedView,
			      let draggedIndex = draggedIndex,
			      let dropIndicator = dropIndicatorView,
			      let draggedClone = draggedCloneView else { return }

			// Convert event point to view coordinates
			let point = contentView.convert(event.locationInWindow, from: nil)

			// Update dragged clone position
			draggedClone.frame.origin.y = point.y - dragOffset
			// Hide drop indicator by default
			dropIndicator.isHidden = true

			// Find which item view we're hovering over
			var targetIndex: Int?
			for (index, itemView) in itemViews.enumerated() {
				if index != draggedIndex &&
					point.y >= itemView.frame.minY &&
					point.y <= itemView.frame.maxY
				{
					// Show drop indicator
					showDropIndicator(at: index)
					targetIndex = index
					break
				}
			}

			// If mouse is released (button up), perform the swap
			if event.type == .leftMouseUp {
				NSAnimationContext.runAnimationGroup { context in
					context.duration = 0.3

					if let targetIndex = targetIndex {
						moveItem(from: draggedIndex, to: targetIndex)
					} else {
						// If not dropped on a valid position, reset the layout
						snapshotCurrentConditions()
						updateItems()
					}

					// End the drag operation
					handleDragEnd(draggedView)
				}
			}
		}

		private func moveItem(from fromIndex: Int, to toIndex: Int) {
			snapshotCurrentConditions()
			guard fromIndex != toIndex,
			      conditions.indices.contains(fromIndex),
			      conditions.indices.contains(toIndex) else { return }

			// Get the condition to move
			let condition = conditions.remove(at: fromIndex)

			// Insert at the target position
			conditions.insert(condition, at: toIndex)

			// Update the views
			updateItems()
		}

		private func showDropIndicator(at index: Int) {
			guard let indicator = dropIndicatorView,
			      itemViews.indices.contains(index) else { return }

			let targetView = itemViews[index]

			// Show indicator above or below based on dragged index
			guard let draggedIndex else { return }
			let isDraggingDown = draggedIndex < index

			// Position indicator
			indicator.isHidden = false
			indicator.frame = NSRect(
				x: targetView.frame.minX,
				y: isDraggingDown ? targetView.frame.maxY - 2 : targetView.frame.minY - 2,
				width: targetView.frame.width,
				height: 4
			)
		}

		private func handleDragEnd(_ view: ConditionFormItemView) {
			view.alphaValue = 1.0
			cleanUpDragState()
		}

		private func cleanUpDragState() {
			draggedView?.alphaValue = 1.0

			// Remove the clone view
			draggedCloneView?.removeFromSuperview()
			draggedCloneView = nil

			// Hide drop indicator
			dropIndicatorView?.isHidden = true

			// Stop tracking mouse movement
			if let monitor = eventMonitor {
				NSEvent.removeMonitor(monitor)
				eventMonitor = nil
			}

			// Reset drag state
			draggedView = nil
			draggedIndex = nil
		}

		private func removeCondition(at index: Int) {
			snapshotCurrentConditions()
			guard conditions.indices.contains(index) else { return }
			conditions.remove(at: index)
			updateItems()
		}

		func layout() {
            contentView.snp.remakeConstraints { make in
                make.top.horizontalEdges.equalToSuperview()
				if let lastView = itemViews.last {
					make.bottom.equalTo(lastView.snp.bottom).offset(16)
				} else {
					make.bottom.equalToSuperview()
				}
			}
		}

		private func setupUI() {
			view.addSubview(titleLabel)
			view.addSubview(scrollView)
			view.addSubview(buttonStack)

			setupButtonStack()

			// MARK: - ScrollView

			scrollView.documentView = contentView
			contentView.snp.makeConstraints { make in
				make.top.horizontalEdges.equalToSuperview()
			}
			layout()

			scrollView.snp.makeConstraints { make in
				make.top.equalTo(titleLabel.snp.bottom).offset(16)
				make.left.right.equalToSuperview().inset(20)
				make.bottom.equalTo(buttonStack.snp.top).offset(-16)
			}

			// MARK: - Title Label

			titleLabel.snp.makeConstraints { make in
				make.top.equalToSuperview().offset(16)
				make.left.equalToSuperview().offset(20)
			}
		}

		private func setupButtonStack() {
			buttonStack.addArrangedSubview(addButton)

			let rightStack = NSStackView()
			rightStack.orientation = .horizontal
			rightStack.distribution = .fill
			rightStack.addArrangedSubview(closeModalButton)
			rightStack.addArrangedSubview(saveButton)
			buttonStack.addArrangedSubview(rightStack)

			buttonStack.snp.makeConstraints { make in
				make.bottom.equalToSuperview().inset(16)
				make.horizontalEdges.equalToSuperview().inset(20)
			}
		}
	}
}

extension PreferencesIntegrationSlackView.EmojiConditionViewController {
	@objc func cancel() {
		dismiss(nil)
	}

	@objc func save() {
		if let invalidIndex = itemViews.firstIndex(where: { $0.validationError != nil }),
		   let validationError = itemViews[invalidIndex].validationError
		{
			ToastManager.shared.error("Condition \(invalidIndex + 1): \(validationError)")
			return
		}

		snapshotCurrentConditions()

		// 更新到 Preferences 中
		let previousIntegration = PreferencesDataModel.shared.slackIntegration.value
		var integration = previousIntegration
		integration.customEmojiConditionList = EmojiConditionList(conditions: conditions)
		guard integration.persistCredentialChanges(comparedTo: previousIntegration) else {
			ToastManager.shared.error("Could not verify the Slack API token in Keychain")
			return
		}
		PreferencesDataModel.shared.slackIntegration.accept(integration)

		// 关闭窗口
		dismiss(nil)
	}

	@objc func addCondition() {
		snapshotCurrentConditions()
		conditions.append(.init(when: "", emoji: ""))
		updateItems()
	}
}

private class ConditionFormItemView: NSView {
	private lazy var formContainer: NSView = {
		let view = NSView()
		view.wantsLayer = true
		return view
	}()

	private lazy var conditionContainer: NSView = {
		let view = NSView()
		view.wantsLayer = true
		return view
	}()

	private lazy var dragHandle: NSButton = {
		let button = NSButton()
		button.image = NSImage(systemSymbolName: "arrow.up.and.down.circle", accessibilityDescription: "Drag to reorder")
		button.bezelStyle = .inline
		button.isBordered = false
		button.isEnabled = true

		// Add hover effect
		button.trackingAreas.forEach { button.removeTrackingArea($0) }
		let trackingArea = NSTrackingArea(
			rect: button.bounds,
			options: [.mouseEnteredAndExited, .activeAlways],
			owner: button,
			userInfo: nil
		)
		button.addTrackingArea(trackingArea)

		return button
	}()

	private lazy var ifLabel: NSTextField = {
		let label = NSTextField(labelWithString: "If")
		return label
	}()

	private lazy var fieldPopup: NSPopUpButton = {
		let popup = NSPopUpButton()
		popup.addItems(withTitles: EmojiConditionList.EmojiCondition.Variable.allCases.map { $0.toCopyableString() })
		popup.bezelStyle = .rounded
		popup.target = self
		popup.action = #selector(fieldChanged)
		return popup
	}()

	private lazy var conditionPopup: NSPopUpButton = {
		let popup = NSPopUpButton()
		popup.addItems(withTitles: EmojiConditionList.EmojiCondition.Condition.allCases.map { $0.rawValue })
		popup.bezelStyle = .rounded
		popup.target = self
		popup.action = #selector(conditionChanged)
		return popup
	}()

	private lazy var valueTextField: NSTextField = {
		let textField = NSTextField()
		textField.placeholderString = "Enter value..."
		return textField
	}()

	private lazy var appPickerButton: NSButton = {
		let button = NSButton()
		button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Select application")
		button.bezelStyle = .inline
		button.isBordered = false
		button.target = self
		button.action = #selector(openAppPicker)
		button.isHidden = true
		return button
	}()

	private lazy var thenSetEmojiLabel: NSTextField = {
		let label = NSTextField(labelWithString: "then set emoji to")
		return label
	}()

	private lazy var emojiTextField: NSTextField = {
		let textField = NSTextField()
		textField.placeholderString = "Enter emoji..."
		return textField
	}()

	private lazy var emojiPickerButton: NSButton = {
		let button = NSButton(title: "😀", target: nil, action: #selector(NSApp.orderFrontCharacterPalette))
		let emojiImage = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "open emoji panel")
		button.image = emojiImage
		button.target = NSApp
		button.bezelStyle = .inline
		button.isBordered = false
		return button
	}()

	private lazy var deleteButton: NSButton = {
		let button = NSButton()
		button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete condition")
		button.bezelStyle = .inline
		button.isBordered = false
		button.target = self
		button.action = #selector(deleteCondition)
		return button
	}()

	var index: Int = 0
	var onDelete: (() -> Void)?
	var onDragStart: ((ConditionFormItemView) -> Void)?
	var onDragEnded: ((ConditionFormItemView) -> Void)?

	var validationError: String? {
		if valueTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return "the comparison value is required"
		}
		if emojiTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return "the emoji is required"
		}
		return nil
	}

	@objc private func deleteCondition() {
		onDelete?()
	}

	@objc private func fieldChanged() {
		updateAppPickerVisibility()
	}

	@objc private func conditionChanged() {
		updateAppPickerVisibility()
	}

	private func updateAppPickerVisibility() {
		let allowedApplicationInentifier: Set<EmojiConditionList.EmojiCondition.Variable> = [.processApplicationIdentifier, .mediaProcessApplicationIdentifier]
		let isAppId = allowedApplicationInentifier.contains(EmojiConditionList.EmojiCondition.Variable.allCases[fieldPopup.indexOfSelectedItem])
		let isEquals = EmojiConditionList.EmojiCondition.Condition.allCases[conditionPopup.indexOfSelectedItem] == .equals

		appPickerButton.isHidden = !(isAppId && isEquals)
	}

	@objc private func openAppPicker() {
		AppPickerView.showAppPicker(for: appPickerButton) { [weak self] appId, _ in
			guard let self = self else { return }
			self.valueTextField.stringValue = appId ?? ""
		}
	}

	init(initialValue: EmojiConditionList.EmojiCondition? = nil) {
		super.init(frame: .zero)

		setupUI()

		if let initialValue = initialValue {
			setValues(from: initialValue)
		}

		updateAppPickerVisibility()
	}

	private func setValues(from condition: EmojiConditionList.EmojiCondition) {
		if let parsedCondition = EmojiConditionList.EmojiCondition.parseWhenString(for: condition.when) {
			// 设置表达式下拉菜单
			for (index, variable) in EmojiConditionList.EmojiCondition.Variable.allCases.enumerated() {
				if variable == parsedCondition.variable {
					fieldPopup.selectItem(at: index)
					break
				}
			}

			// 设置条件下拉菜单
			for (index, condition) in EmojiConditionList.EmojiCondition.Condition.allCases.enumerated() {
				if condition == parsedCondition.condition {
					conditionPopup.selectItem(at: index)
					break
				}
			}

			// 设置值
			valueTextField.stringValue = parsedCondition.value
		}

		// 设置 emoji
		emojiTextField.stringValue = condition.emoji

		// Update app picker visibility based on current selection
		updateAppPickerVisibility()
	}

	func saveCondition() -> EmojiConditionList.EmojiCondition {
		// 获取选中的变量
		let variableIndex = fieldPopup.indexOfSelectedItem
		let variable = EmojiConditionList.EmojiCondition.Variable.allCases[variableIndex]

		// 获取选中的条件
		let conditionIndex = conditionPopup.indexOfSelectedItem
		let condition = EmojiConditionList.EmojiCondition.Condition.allCases[conditionIndex]

		// 构建 when 字符串: "{variable} condition "value""
		let value = valueTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		let emoji = emojiTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		let whenString = "{\(variable.rawValue)} \(condition.rawValue) \"\(value)\""

		// 返回新的条件对象
		return EmojiConditionList.EmojiCondition(when: whenString, emoji: emoji)
	}

	func sizeToFit() {
		snp.makeConstraints { make in
			make.bottom.equalTo(conditionContainer).offset(8)
		}
	}

	private func setupUI() {
		addSubview(formContainer)
		formContainer.addSubview(conditionContainer)
		formContainer.addSubview(emojiPickerButton)
		formContainer.addSubview(deleteButton)

		formContainer.snp.makeConstraints { make in
			make.edges.equalToSuperview()
		}

		conditionContainer.addSubview(dragHandle)
		conditionContainer.addSubview(ifLabel)
		conditionContainer.addSubview(fieldPopup)
		conditionContainer.addSubview(conditionPopup)
		conditionContainer.addSubview(valueTextField)
		conditionContainer.addSubview(appPickerButton)
		conditionContainer.addSubview(thenSetEmojiLabel)
		conditionContainer.addSubview(emojiTextField)

		conditionContainer.snp.makeConstraints { make in
			make.top.equalTo(snp.top).offset(16)
			make.left.right.equalToSuperview().inset(20)
		}

		dragHandle.snp.makeConstraints { make in
			make.bottom.equalTo(deleteButton)
			make.right.equalTo(deleteButton.snp.left).offset(-8)
			make.width.equalTo(20)
			make.height.equalTo(24)
		}

		ifLabel.snp.makeConstraints { make in
			make.left.equalToSuperview()
			make.bottom.equalTo(fieldPopup).offset(-4)
		}

		fieldPopup.snp.makeConstraints { make in
			make.top.equalToSuperview()
			make.left.equalTo(ifLabel.snp.right).offset(8)
			make.width.equalTo(200)
			make.height.equalTo(24)
		}

		conditionPopup.snp.makeConstraints { make in
			make.top.equalToSuperview()
			make.left.equalTo(fieldPopup.snp.right).offset(8)
			make.width.equalTo(100)
			make.height.equalTo(24)
		}

		valueTextField.snp.makeConstraints { make in
			make.top.equalToSuperview()
			make.left.equalTo(conditionPopup.snp.right).offset(8)
			make.right.equalToSuperview()
			make.height.equalTo(24)
		}

		appPickerButton.snp.makeConstraints { make in
			make.centerY.equalTo(valueTextField)
			make.right.equalTo(valueTextField.snp.right).offset(-4)
			make.size.equalTo(24)
		}

		thenSetEmojiLabel.snp.makeConstraints { make in
			make.left.equalToSuperview()
			make.bottom.equalTo(emojiTextField.snp.bottom).offset(-4)
		}

		emojiTextField.snp.makeConstraints { make in
			make.top.equalTo(fieldPopup.snp.bottom).offset(16)
			make.left.equalTo(thenSetEmojiLabel.snp.right).offset(8)
			make.width.equalTo(200)
			make.height.equalTo(24)
			make.bottom.equalToSuperview()
		}

		emojiPickerButton.snp.makeConstraints { make in
			make.centerY.equalTo(emojiTextField)
			make.left.equalTo(emojiTextField.snp.right).offset(4)
			make.size.equalTo(24)
		}

		deleteButton.snp.makeConstraints { make in
			make.bottom.equalTo(emojiPickerButton)
			make.right.equalToSuperview().offset(-18)
			make.size.equalTo(24)
		}

		// Set up drag and drop
		setupDragAndDrop()
	}

	private func setupDragAndDrop() {
		dragHandle.toolTip = "Drag to reorder this condition"
		let dragGesture = NSPanGestureRecognizer(target: self, action: #selector(handleDragGesture(_:)))
		dragHandle.addGestureRecognizer(dragGesture)
	}

	@objc private func handleDragGesture(_ gestureRecognizer: NSPanGestureRecognizer) {
		switch gestureRecognizer.state {
		case .began:
			// Begin drag
			dragHandle.alphaValue = 0.7
			onDragStart?(self)
		case .changed:
			// Update during drag - don't need to do anything here as the controller will handle reordering
			break
		case .ended, .cancelled:
			// End drag
			dragHandle.alphaValue = 1.0
			onDragEnded?(self)
		default:
			break
		}
	}

	func snapshot() -> NSImage {
		let image = NSImage(size: bounds.size)
		image.lockFocus()
		if let context = NSGraphicsContext.current {
			layer?.render(in: context.cgContext)
		}
		image.unlockFocus()
		return image
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}
