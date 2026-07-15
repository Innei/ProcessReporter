import SwiftUI

struct DestinationEditorLayout<Required: View, Content: View, Advanced: View>: View {
    let destination: SettingsDestination
    let status: SettingsConfigurationStatus
    @Binding var isEnabled: Bool
    let notice: DestinationOperationNotice?
    let isBusy: Bool
    let isDirty: Bool
    let testTitle: String
    let onTest: () -> Void
    let onDiscard: () -> Void
    let onSave: () -> Void
    var onBack: (() -> Void)? = nil
    @ViewBuilder let required: Required
    @ViewBuilder let content: Content
    @ViewBuilder let advanced: Advanced

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DestinationEditorHeader(
                        destination: destination,
                        status: status,
                        isEnabled: $isEnabled,
                        isBusy: isBusy,
                        onBack: onBack
                    )

                    DestinationEditorSection("Required") {
                        required
                    }
                    .disabled(isBusy || status.isLoadingCredentials)

                    DestinationEditorSection("Content / Preview") {
                        content
                    }
                    .disabled(isBusy || status.isLoadingCredentials)

                    DestinationEditorSection("Advanced") {
                        advanced
                    }
                    .disabled(isBusy || status.isLoadingCredentials)

                    if let notice {
                        DestinationEditorNotice(notice: notice)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            Divider()

            DestinationEditorFooter(
                isBusy: isBusy,
                isLoadingCredentials: status.isLoadingCredentials,
                isDirty: isDirty,
                testTitle: testTitle,
                onTest: onTest,
                onDiscard: onDiscard,
                onSave: onSave
            )
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct DestinationEditorHeader: View {
    let destination: SettingsDestination
    let status: SettingsConfigurationStatus
    @Binding var isEnabled: Bool
    let isBusy: Bool
    let onBack: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let onBack {
                Button("Back", systemImage: "chevron.backward", action: onBack)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .disabled(isBusy)
                    .help("Back to Destinations")
            }

            Image(nsImage: destination.image)
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(destination.title)
                    .font(.title2.weight(.semibold))
                Text(destination.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(status.title, systemImage: status.symbolName)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 12)

            Toggle("Enabled", isOn: $isEnabled)
                .toggleStyle(.switch)
                .disabled(
                    status.isLoadingCredentials
                        || isBusy
                        || (!status.isValid && !isEnabled)
                )
                .help(
                    !status.isValid && !isEnabled
                        ? "Save a valid configuration before enabling this destination."
                        : "Enable or disable this saved configuration."
                )
        }
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        if status.isConfigured && !status.isValid { return .orange }
        return status.isEnabled ? .green : .secondary
    }
}

struct DestinationEditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }
        }
    }
}

struct DestinationFormRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 180, alignment: .leading)

            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DestinationCredentialField: View {
    let title: String
    let placeholder: String
    @Binding var credential: DestinationCredentialDraft
    var onRemove: () -> Void = {}

    var body: some View {
        DestinationFormRow(title, detail: "Protected credential") {
            VStack(alignment: .leading, spacing: 8) {
                switch credential.intent {
                case .unchanged where credential.hadStoredValue:
                    HStack(spacing: 10) {
                        Label("Stored ••••••••", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Button("Replace", action: beginReplacement)
                        Button("Remove", role: .destructive, action: removeCredential)
                    }
                case .remove:
                    HStack(spacing: 10) {
                        Label("Credential will be removed when saved", systemImage: "trash")
                            .foregroundStyle(.orange)
                        Button("Undo", action: keepStoredCredential)
                    }
                default:
                    SecureField(placeholder, text: $credential.replacement)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(title)
                        .accessibilityHint(
                            "This value is not stored until Save Changes is selected."
                        )
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(pendingCredentialMessage, systemImage: "pencil.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if credential.hadStoredValue {
                            Button("Cancel Replacement", action: keepStoredCredential)
                                .buttonStyle(.link)
                                .accessibilityHint(
                                    "Discards the replacement and continues using the stored credential."
                                )
                        }
                    }
                }
            }
        }
    }

    private var pendingCredentialMessage: String {
        if credential.hadStoredValue {
            "Replacement not saved. Choose Save Changes below to apply it."
        } else {
            "Credential not saved. Choose Save Changes below to store it."
        }
    }

    private func beginReplacement() {
        credential.beginReplacement()
    }

    private func removeCredential() {
        credential.remove()
        onRemove()
    }

    private func keepStoredCredential() {
        credential.keepStoredValue()
    }
}

struct DestinationPreviewCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: "eye")
                .font(.subheadline.weight(.medium))

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Text(row.1.isEmpty ? "—" : row.1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DestinationEditorNotice: View {
    let notice: DestinationOperationNotice

    var body: some View {
        Label(notice.message, systemImage: symbolName)
            .font(.subheadline)
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch notice.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

private struct DestinationEditorFooter: View {
    let isBusy: Bool
    let isLoadingCredentials: Bool
    let isDirty: Bool
    let testTitle: String
    let onTest: () -> Void
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(testTitle, systemImage: "checkmark.shield", action: onTest)
                .disabled(isBusy || isLoadingCredentials)

            if isBusy || isLoadingCredentials {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        isBusy
                            ? "Destination operation in progress"
                            : "Loading protected credentials"
                    )
            }

            Spacer()

            Button("Discard Changes", action: onDiscard)
                .disabled(isBusy || isLoadingCredentials || !isDirty)
            Button("Save Changes", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || isLoadingCredentials || !isDirty)
                .accessibilityHint("Saves configuration and pending credential changes.")
        }
    }
}
