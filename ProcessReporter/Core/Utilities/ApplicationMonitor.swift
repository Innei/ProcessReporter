//
//  ApplicationMonitor.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/7.
//

import Accessibility
import AppKit
import Foundation

/// Main-actor owner for AppKit event monitors and Accessibility observers.
/// Read APIs are side-effect free; permission prompts occur only when a caller
/// explicitly starts a monitor.
@MainActor
final class ApplicationMonitor {
  static let shared = ApplicationMonitor()

  private var mouseEventMonitor: Any?
  private var mouseMonitoringGeneration: UInt64 = 0
  private var workspaceActivationObserver: Any?
  private var windowMonitoringGeneration: UInt64 = 0
  private var accessibilityObserver: AXObserver?
  private var accessibilityObserverIdentity: UInt?
  private var observedApplicationElement: AXUIElement?
  private var observedWindowElement: AXUIElement?
  private var didRequestAccessibilityPermission = false
  private var didPresentPermissionExplanation = false

  var onMouseClicked: ((MouseClickInfo) -> Void)?
  var onWindowFocusChanged: ((FocusedWindowInfo) -> Void)?

  private init() {}

  func isAccessibilityEnabled() -> Bool {
    AXIsProcessTrusted()
  }

  private func requestAccessibilityPermissionIfNeeded() -> Bool {
    guard !isAccessibilityEnabled() else { return true }

    if !didRequestAccessibilityPermission {
      didRequestAccessibilityPermission = true
      // The imported Core Foundation global is not concurrency-annotated.
      // Its documented string value avoids reading that shared global here.
      let options = ["AXTrustedCheckOptionPrompt": true]
      return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    guard !didPresentPermissionExplanation else { return false }
    didPresentPermissionExplanation = true

    let alert = NSAlert()
    alert.messageText = "Accessibility Permission Required"
    alert.informativeText =
      "ProcessReporter needs Accessibility permission to read the focused window. "
      + "Grant access in System Settings > Privacy & Security > Accessibility."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Later")

    if alert.runModal() == .alertFirstButtonReturn,
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    {
      NSWorkspace.shared.open(url)
    }
    return false
  }

  private func getWindowTitle(forPID processID: pid_t) -> String? {
    let applicationElement = AXUIElementCreateApplication(processID)

    var value: CFTypeRef?
    let focusedWindowResult = AXUIElementCopyAttributeValue(
      applicationElement,
      kAXFocusedWindowAttribute as CFString,
      &value
    )
    if focusedWindowResult != .success {
      value = nil
      guard
        AXUIElementCopyAttributeValue(
          applicationElement,
          kAXMainWindowAttribute as CFString,
          &value
        ) == .success
      else { return nil }
    }
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }

    // The Core Foundation type check above makes this bridge safe.
    let window = value as! AXUIElement
    var titleValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        window,
        kAXTitleAttribute as CFString,
        &titleValue
      ) == .success
    else { return nil }

    return titleValue as? String
  }

  private func shouldIgnoreApplication(identifier: String) -> Bool {
    if IgnoreSystemApplication.contains(identifier) { return true }
    guard let ownIdentifier = Bundle.main.bundleIdentifier else { return false }
    return identifier == ownIdentifier
  }

  /// Returns the frontmost process identity without showing permission UI.
  /// Accessibility permission gates only the focused-window title.
  func getFocusedWindowInfo() -> FocusedWindowInfo? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }

    let applicationIdentifier = application.bundleIdentifier ?? ""
    guard !shouldIgnoreApplication(identifier: applicationIdentifier) else { return nil }

    // Process identity is available through NSWorkspace without
    // Accessibility permission. Only the window title is capability-gated.
    let title =
      isAccessibilityEnabled()
      ? getWindowTitle(forPID: application.processIdentifier)
      : nil

    return FocusedWindowInfo(
      appName: application.localizedName ?? "Unknown",
      icon: application.icon?.copy() as? NSImage,
      applicationIdentifier: applicationIdentifier,
      title: title
    )
  }

  func startMouseMonitoring() {
    stopMouseMonitoring()

    // There is no reason to install a privacy-sensitive global event tap
    // when the application has not registered a consumer.
    guard onMouseClicked != nil else { return }
    guard requestAccessibilityPermissionIfNeeded() else { return }
    let generation = mouseMonitoringGeneration

    mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown,
    ]) { [weak self] event in
      let clickInfo = MouseClickInfo(
        location: NSEvent.mouseLocation,
        timestamp: event.timestamp
      )
      Task { @MainActor [weak self] in
        guard
          let self,
          generation == mouseMonitoringGeneration,
          mouseEventMonitor != nil
        else { return }
        onMouseClicked?(clickInfo)
      }
    }
  }

  func stopMouseMonitoring() {
    mouseMonitoringGeneration &+= 1
    if let monitor = mouseEventMonitor {
      NSEvent.removeMonitor(monitor)
      mouseEventMonitor = nil
    }
  }

  func startWindowFocusMonitoring() {
    stopWindowFocusMonitoring()
    let generation = windowMonitoringGeneration

    // NSWorkspace activation notifications do not require Accessibility
    // permission and continue to provide app-level process reporting.
    workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleApplicationActivation(generation: generation)
      }
    }

    if requestAccessibilityPermissionIfNeeded() {
      attachAccessibilityObserverToFrontmostApplication()
    }
  }

  func stopWindowFocusMonitoring() {
    windowMonitoringGeneration &+= 1
    if let observer = workspaceActivationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      workspaceActivationObserver = nil
    }
    detachAccessibilityObserver()
  }

  private func handleApplicationActivation(generation: UInt64) {
    guard
      generation == windowMonitoringGeneration,
      workspaceActivationObserver != nil
    else { return }
    attachAccessibilityObserverToFrontmostApplication()
    emitFocusedWindowChange()
  }

  private func emitFocusedWindowChange() {
    guard let windowInfo = getFocusedWindowInfo() else { return }
    onWindowFocusChanged?(windowInfo)
  }

  private func attachAccessibilityObserverToFrontmostApplication() {
    detachAccessibilityObserver()
    guard isAccessibilityEnabled() else { return }

    guard let application = NSWorkspace.shared.frontmostApplication else { return }
    let applicationIdentifier = application.bundleIdentifier ?? ""
    guard !shouldIgnoreApplication(identifier: applicationIdentifier) else { return }

    var observer: AXObserver?
    guard
      AXObserverCreate(
        application.processIdentifier,
        Self.accessibilityNotificationCallback,
        &observer
      ) == .success,
      let observer
    else { return }

    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      AXObserverAddNotification(
        observer,
        applicationElement,
        kAXFocusedWindowChangedNotification as CFString,
        context
      ) == .success
    else { return }

    accessibilityObserver = observer
    accessibilityObserverIdentity = Self.identity(of: observer)
    observedApplicationElement = applicationElement
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
    refreshObservedWindow()
  }

  private func refreshObservedWindow() {
    guard
      let observer = accessibilityObserver,
      let applicationElement = observedApplicationElement
    else { return }

    if let oldWindow = observedWindowElement {
      AXObserverRemoveNotification(
        observer,
        oldWindow,
        kAXTitleChangedNotification as CFString
      )
      observedWindowElement = nil
    }

    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        applicationElement,
        kAXFocusedWindowAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return }

    let window = value as! AXUIElement
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      AXObserverAddNotification(
        observer,
        window,
        kAXTitleChangedNotification as CFString,
        context
      ) == .success
    else { return }
    observedWindowElement = window
  }

  private func detachAccessibilityObserver() {
    guard let observer = accessibilityObserver else {
      accessibilityObserverIdentity = nil
      observedApplicationElement = nil
      observedWindowElement = nil
      return
    }

    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
    accessibilityObserver = nil
    accessibilityObserverIdentity = nil
    observedApplicationElement = nil
    observedWindowElement = nil
  }

  private static func identity(of observer: AXObserver) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
  }

  private static let accessibilityNotificationCallback: AXObserverCallback = {
    observer, _, notification, context in
    guard let context else { return }
    let monitor = Unmanaged<ApplicationMonitor>.fromOpaque(context).takeUnretainedValue()
    let observerIdentity = identity(of: observer)
    let focusedWindowChanged = notification as String == kAXFocusedWindowChangedNotification

    Task { @MainActor in
      guard monitor.accessibilityObserverIdentity == observerIdentity else { return }
      if focusedWindowChanged {
        monitor.refreshObservedWindow()
      }
      monitor.emitFocusedWindowChange()
    }
  }
}
