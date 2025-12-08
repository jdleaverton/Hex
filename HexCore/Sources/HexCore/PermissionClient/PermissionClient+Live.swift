@preconcurrency import AppKit
import AVFoundation
import CoreGraphics
import Dependencies
import Foundation
import IOKit
import IOKit.hidsystem

private let logger = HexLog.permissions

extension PermissionClient: DependencyKey {
  public static var liveValue: Self {
    let live = PermissionClientLive()
    return Self(
      microphoneStatus: { await live.microphoneStatus() },
      accessibilityStatus: { live.accessibilityStatus() },
      inputMonitoringStatus: { live.inputMonitoringStatus() },
      requestMicrophone: { await live.requestMicrophone() },
      requestAccessibility: { await live.requestAccessibility() },
      requestInputMonitoring: { await live.requestInputMonitoring() },
      openMicrophoneSettings: { await live.openMicrophoneSettings() },
      openAccessibilitySettings: { await live.openAccessibilitySettings() },
      openInputMonitoringSettings: { await live.openInputMonitoringSettings() },
      observeAppActivation: { live.observeAppActivation() },
      observePermissionChanges: { live.observePermissionChanges() },
      triggerPermissionRefresh: { live.triggerPermissionRefresh() }
    )
  }
}

/// Live implementation of the PermissionClient.
///
/// This actor manages permission checking, requesting, and app activation monitoring.
/// It uses NotificationCenter to observe app lifecycle events and provides an AsyncStream
/// for reactive permission updates.
///
/// ## Permission Change Detection
///
/// macOS provides limited APIs for observing permission changes. This implementation uses:
/// - `NSApplication.didBecomeActiveNotification` - triggered when user returns from System Settings
/// - `DistributedNotificationCenter` with `com.apple.accessibility.api` - experimental but useful
///   for detecting accessibility changes without requiring app restart
///
/// Note: When permissions change in System Settings, macOS typically terminates the app,
/// so app activation monitoring catches most cases on next launch.
actor PermissionClientLive {
  private let (activationStream, activationContinuation) = AsyncStream<AppActivation>.makeStream()
  private let (permissionChangeStream, permissionChangeContinuation) = AsyncStream<PermissionChange>.makeStream()
  private nonisolated(unsafe) var observations: [Any] = []

  init() {
    logger.debug("Initializing PermissionClient, setting up observers")

    // Subscribe to app activation notifications
    let didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      logger.debug("App became active - triggering permission check")
      Task {
        self?.activationContinuation.yield(.didBecomeActive)
        self?.permissionChangeContinuation.yield(.appBecameActive)
      }
    }

    let willResignActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      logger.debug("App will resign active")
      Task {
        self?.activationContinuation.yield(.willResignActive)
      }
    }

    // Experimental: DistributedNotificationCenter for accessibility changes
    // This is undocumented but fires when any app's accessibility permission changes.
    // We use a small delay before checking because the permission state takes time to update.
    let accessibilityObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.accessibility.api"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      logger.debug("Received com.apple.accessibility.api notification - scheduling permission check")
      // Delay slightly because the permission database takes time to update
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        Task {
          self?.permissionChangeContinuation.yield(.accessibilityMayHaveChanged)
        }
      }
    }

    observations = [didBecomeActiveObserver, willResignActiveObserver, accessibilityObserver]
    logger.info("PermissionClient initialized with app activation and accessibility observers")
  }

  deinit {
    observations.forEach { observer in
      NotificationCenter.default.removeObserver(observer)
      DistributedNotificationCenter.default().removeObserver(observer)
    }
  }

  // MARK: - Microphone Permissions

  func microphoneStatus() async -> PermissionStatus {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    let result: PermissionStatus
    switch status {
    case .authorized:
      result = .granted
    case .denied, .restricted:
      result = .denied
    case .notDetermined:
      result = .notDetermined
    @unknown default:
      result = .denied
    }
    logger.info("Microphone status: \(String(describing: result))")
    return result
  }

  func requestMicrophone() async -> Bool {
    logger.info("Requesting microphone permission...")
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
    logger.info("Microphone permission granted: \(granted)")
    return granted
  }

  func openMicrophoneSettings() async {
    logger.info("Opening microphone settings in System Preferences...")
    await MainActor.run {
      _ = NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
      )
    }
  }

  // MARK: - Accessibility Permissions

  nonisolated func accessibilityStatus() -> PermissionStatus {
    // Check without prompting (kAXTrustedCheckOptionPrompt: false)
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    let result = AXIsProcessTrustedWithOptions(options) ? PermissionStatus.granted : .denied
    logger.info("Accessibility status: \(String(describing: result))")
    return result
  }

  nonisolated func inputMonitoringStatus() -> PermissionStatus {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let result = mapIOHIDAccess(access)
    logger.info("Input monitoring status: \(String(describing: result)) (IOHIDAccess: \(String(describing: access)))")
    return result
  }

  func requestAccessibility() async {
    logger.info("Requesting accessibility permission...")
    // First, trigger the system prompt (on main actor for safety)
    await MainActor.run {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }

    // Also open System Settings (the prompt alone is insufficient on modern macOS)
    await openAccessibilitySettings()
  }

  func requestInputMonitoring() async -> Bool {
    logger.info("Requesting input monitoring permission...")
    let granted = await MainActor.run {
      if CGPreflightListenEventAccess() {
        return true
      }
      return CGRequestListenEventAccess()
    }

    if !granted {
      logger.info("Input monitoring not granted, opening Settings...")
      await openInputMonitoringSettings()
    } else {
      logger.info("Input monitoring permission granted: \(granted)")
    }

    return granted
  }

  func openAccessibilitySettings() async {
    logger.info("Opening accessibility settings in System Preferences...")
    await MainActor.run {
      _ = NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
      )
    }
  }

  func openInputMonitoringSettings() async {
    logger.info("Opening input monitoring settings in System Preferences...")
    await MainActor.run {
      _ = NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
      )
    }
  }

  // MARK: - Reactive Monitoring

  nonisolated func observeAppActivation() -> AsyncStream<AppActivation> {
    activationStream
  }

  nonisolated func observePermissionChanges() -> AsyncStream<PermissionChange> {
    permissionChangeStream
  }

  nonisolated func triggerPermissionRefresh() {
    logger.debug("Manual permission refresh triggered")
    permissionChangeContinuation.yield(.refreshRequested)
  }

  private nonisolated func mapIOHIDAccess(_ access: IOHIDAccessType) -> PermissionStatus {
    switch access {
    case kIOHIDAccessTypeGranted:
      return .granted
    case kIOHIDAccessTypeDenied:
      return .denied
    default:
      return .notDetermined
    }
  }
}
