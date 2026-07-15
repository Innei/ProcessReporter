import AppKit
import SwiftUI

enum LegacySettingsControllerKind {
    case mappings
}

struct LegacySettingsControllerRepresentable: NSViewControllerRepresentable {
    let kind: LegacySettingsControllerKind

    func makeNSViewController(context: Context) -> NSViewController {
        switch kind {
        case .mappings:
            return PreferencesMappingViewController()
        }
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

struct LegacySettingsPage: View {
    let title: String
    let subtitle: String
    var context: String? = nil
    let controller: LegacySettingsControllerKind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let context {
                    Label(context, systemImage: "scope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            LegacySettingsControllerRepresentable(kind: controller)
        }
    }
}
