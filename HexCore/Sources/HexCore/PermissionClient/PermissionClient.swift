import Dependencies
import DependenciesMacros
import Foundation

// MARK: - Permission Change Events

/// Represents a change in permission status that should trigger a re-check.
///
/// Permission changes can occur due to:
/// - App becoming active (user may have changed permissions in System Settings)
/// - DistributedNotificationCenter broadcasts (accessibility changes)
/// - External triggers like CGEventTap failures
public enum PermissionChange: Equatable, Sendable {
  /// App became active - should re-check all permissions
  case appBecameActive

  /// Accessibility permission may have changed (via DistributedNotificationCenter)
  case accessibilityMayHaveChanged

  /// Explicit request to refresh all permissions
  case refreshRequested
}

// MARK: - Permission Client

/// A client for managing system permissions (microphone, accessibility) in a composable way.
///
/// This client provides a unified interface for checking permission status, requesting permissions,
/// and monitoring app activation events to reactively update permission state.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.permissions) var permissions
///
/// // Check current status
/// let micStatus = await permissions.microphoneStatus()
///
/// // Request permission
/// let granted = await permissions.requestMicrophone()
///
/// // Monitor app activation for reactive updates
/// for await activation in permissions.observeAppActivation() {
///   if case .didBecomeActive = activation {
///     // Re-check permissions
///   }
/// }
/// ```
@DependencyClient
public struct PermissionClient: Sendable {
  /// Check the current microphone permission status.
  ///
  /// This is async to accommodate iOS 18+ where AVCaptureDevice authorization checks
  /// may perform I/O operations. On macOS this is typically instant.
  public var microphoneStatus: @Sendable () async -> PermissionStatus = { .notDetermined }

  /// Check the current accessibility permission status (synchronous).
  ///
  /// Uses `AXIsProcessTrusted` which is a fast, synchronous check.
  public var accessibilityStatus: @Sendable () -> PermissionStatus = { .notDetermined }

  /// Check the current input monitoring permission status (synchronous).
  ///
  /// Uses `IOHIDCheckAccess` to determine whether we can listen for global keyboard events.
  public var inputMonitoringStatus: @Sendable () -> PermissionStatus = { .notDetermined }

  /// Request microphone permission from the user.
  ///
  /// If permission is `.notDetermined`, this will show the system permission dialog.
  /// If already granted or denied, this will return the current status.
  ///
  /// - Returns: `true` if permission was granted, `false` otherwise
  public var requestMicrophone: @Sendable () async -> Bool = { false }

  /// Request accessibility permission from the user.
  ///
  /// This triggers the system permission prompt and opens System Settings to the
  /// Accessibility privacy panel. The user must manually enable the app in Settings.
  public var requestAccessibility: @Sendable () async -> Void = {}

  /// Request input monitoring permission from the user.
  ///
  /// Triggers the consent dialog introduced in macOS Sequoia when listening for keyboard events.
  public var requestInputMonitoring: @Sendable () async -> Bool = { false }

  /// Open System Settings to the microphone privacy panel.
  ///
  /// Useful when permission is denied and the user needs to manually change it.
  public var openMicrophoneSettings: @Sendable () async -> Void = {}

  /// Open System Settings to the accessibility privacy panel.
  ///
  /// Useful when permission is denied and the user needs to manually change it.
  public var openAccessibilitySettings: @Sendable () async -> Void = {}

  /// Open System Settings to the Input Monitoring privacy panel.
  public var openInputMonitoringSettings: @Sendable () async -> Void = {}

  /// Observe app activation events.
  ///
  /// Returns an `AsyncStream` that yields `AppActivation` events when the app
  /// becomes active or resigns active status. Use this to reactively re-check
  /// permissions when the app comes to the foreground.
  ///
  /// - Note: On macOS, the app is killed when permissions change in System Settings,
  ///   so continuous polling is unnecessary. Checking on app activation is sufficient.
  public var observeAppActivation: @Sendable () -> AsyncStream<AppActivation> = { .never }

  /// Observe permission change events.
  ///
  /// Returns an `AsyncStream` that yields `PermissionChange` events when permissions
  /// may have changed. This consolidates multiple sources:
  /// - App activation (user may have changed permissions in System Settings)
  /// - DistributedNotificationCenter for accessibility changes (experimental)
  ///
  /// Subscribe to this stream and re-check permissions when events are received.
  public var observePermissionChanges: @Sendable () -> AsyncStream<PermissionChange> = { .never }

  /// Manually trigger a permission refresh.
  ///
  /// Use this after requesting a permission to signal that a re-check is needed.
  public var triggerPermissionRefresh: @Sendable () -> Void = {}
}

extension DependencyValues {
  /// Access the permission client dependency.
  public var permissions: PermissionClient {
    get { self[PermissionClient.self] }
    set { self[PermissionClient.self] = newValue }
  }
}
