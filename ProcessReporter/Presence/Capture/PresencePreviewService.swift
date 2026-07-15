import Foundation

struct PresenceReviewPreview: Equatable, Sendable {
    let applicationName: String?
    /// Local-only sanitized identity used to evaluate destination rules. Views
    /// must not render this field as Presence content.
    let applicationIdentifier: String?
    let windowTitle: String?
    let mediaTitle: String?
    let mediaArtist: String?
    let mediaApplicationName: String?
    /// Local-only sanitized identity used to evaluate destination rules.
    let mediaApplicationIdentifier: String?
}

@MainActor
enum PresencePreviewService {
    static func captureCurrent() async -> PresenceReviewPreview {
        let enabledTypes = PreferencesDataModel.enabledTypes.value.types
        let configuration = PreferencesDataModel.presencePrivacyConfiguration.value
        let hiddenApplications = Set(PreferencesDataModel.filteredProcesses.value)
        let hiddenMediaApplications = Set(PreferencesDataModel.filteredMediaProcesses.value)
        let hiddenMediaNames = Set(
            hiddenMediaApplications.map { AppUtility.shared.getAppInfo(for: $0).displayName }
        )
        let evaluator = PresencePrivacyEvaluator(
            configuration: configuration,
            legacyHiddenApplications: hiddenApplications,
            legacyHiddenMediaApplications: hiddenMediaApplications,
            legacyHiddenMediaNames: hiddenMediaNames
        )
        let mappings = PreferencesDataModel.mappingList.value.getList()

        var applicationName: String?
        var applicationIdentifier: String?
        var windowTitle: String?
        if enabledTypes.contains(.process),
            let process = ApplicationMonitor.shared.getFocusedWindowInfo()
        {
            let decision = evaluator.processDecision(
                applicationIdentifier: process.applicationIdentifier
            )
            if decision.sharesApplication {
                let legacyName = mappings.first {
                    $0.type == .processName && $0.from == process.appName
                }?.to ?? process.appName
                applicationName = decision.displayAlias ?? legacyName
                applicationIdentifier = mappings.first {
                    $0.type == .processApplicationIdentifier
                        && $0.from == process.applicationIdentifier
                }?.to ?? process.applicationIdentifier
                if PreferencesDataModel.shareWindowTitles.value,
                    decision.sharesWindowTitle
                {
                    windowTitle = process.title
                }
            }
        }

        var mediaTitle: String?
        var mediaArtist: String?
        var mediaApplicationName: String?
        var mediaApplicationIdentifier: String?
        if enabledTypes.contains(.media),
            let media = try? await MediaInfoManager.getMediaInfoAsync(timeout: 2),
            media.playing
        {
            let decision = evaluator.mediaDecision(
                applicationIdentifier: media.applicationIdentifier,
                processName: media.processName
            )
            let hasArtist = media.artist?.isEmpty == false
            if decision.sharesMedia,
                !PreferencesDataModel.ignoreNullArtist.value || hasArtist
            {
                mediaTitle = media.name
                mediaArtist = media.artist
                let legacyName = mappings.first {
                    $0.type == .mediaProcessName && $0.from == media.processName
                }?.to ?? media.processName
                mediaApplicationName = decision.displayAlias ?? legacyName
                mediaApplicationIdentifier = media.applicationIdentifier.map { identifier in
                    mappings.first {
                        $0.type == .mediaProcessApplicationIdentifier
                            && $0.from == identifier
                    }?.to ?? identifier
                }
            }
        }

        return PresenceReviewPreview(
            applicationName: applicationName,
            applicationIdentifier: applicationIdentifier,
            windowTitle: windowTitle,
            mediaTitle: mediaTitle,
            mediaArtist: mediaArtist,
            mediaApplicationName: mediaApplicationName,
            mediaApplicationIdentifier: mediaApplicationIdentifier
        )
    }
}
