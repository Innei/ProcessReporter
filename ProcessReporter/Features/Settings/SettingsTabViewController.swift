import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsTabViewController: NSTabViewController {
    typealias NavigationHandler = (SettingsRoute) -> Bool

    private let store: SettingsStore
    private let navigationHandler: NavigationHandler
    private var selectedSectionSubscription: AnyCancellable?
    private var isApplyingStoreSelection = false
    private var isRequestingSelection = false

    init(store: SettingsStore, navigationHandler: @escaping NavigationHandler) {
        self.store = store
        self.navigationHandler = navigationHandler

        super.init(nibName: nil, bundle: nil)

        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false

        isApplyingStoreSelection = true
        for section in SettingsSection.allCases {
            addTabViewItem(makeTabViewItem(for: section))
        }
        isApplyingStoreSelection = false

        applyStoreSelection(store.selectedSection)
        selectedSectionSubscription = store.$selectedSection
            .removeDuplicates()
            .sink { [weak self] section in
                guard let self, !isRequestingSelection else { return }
                applyStoreSelection(section)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController must be initialized with a SettingsStore.")
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard let window = view.window else { return }
        window.toolbarStyle = .preference
        window.toolbar?.displayMode = .iconAndLabel
        window.toolbar?.allowsUserCustomization = false
        window.toolbar?.autosavesConfiguration = false
    }

    override func tabView(
        _ tabView: NSTabView,
        shouldSelect tabViewItem: NSTabViewItem?
    ) -> Bool {
        guard super.tabView(tabView, shouldSelect: tabViewItem) else { return false }
        guard !isApplyingStoreSelection else { return true }
        guard let section = section(for: tabViewItem) else { return false }
        guard section != store.selectedSection else { return true }

        isRequestingSelection = true
        let accepted = navigationHandler(.section(section))
        isRequestingSelection = false
        return accepted
    }

    private func makeTabViewItem(for section: SettingsSection) -> NSTabViewItem {
        let viewController = NSHostingController(
            rootView: SettingsSectionView(section: section, store: store)
        )
        viewController.title = section.title

        let item = NSTabViewItem(viewController: viewController)
        item.identifier = NSToolbarItem.Identifier(section.rawValue)
        item.label = section.title
        item.image = NSImage(
            systemSymbolName: section.symbolName,
            accessibilityDescription: section.title
        )
        item.toolTip = section.title
        return item
    }

    private func section(for tabViewItem: NSTabViewItem?) -> SettingsSection? {
        guard let tabViewItem,
              let index = tabViewItems.firstIndex(where: { $0 === tabViewItem }),
              SettingsSection.allCases.indices.contains(index)
        else {
            return nil
        }
        return SettingsSection.allCases[index]
    }

    private func applyStoreSelection(_ section: SettingsSection) {
        guard let index = SettingsSection.allCases.firstIndex(of: section),
              selectedTabViewItemIndex != index
        else {
            return
        }

        isApplyingStoreSelection = true
        selectedTabViewItemIndex = index
        isApplyingStoreSelection = false
    }
}
