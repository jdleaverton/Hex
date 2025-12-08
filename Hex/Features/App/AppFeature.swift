//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    case settings
    case transformations
    case history
    case about
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var textTransformations: TextTransformationFeature.State = .init()
		var activeTab: ActiveTab = .settings
		var allowsLLMFeatures: Bool = DeveloperAccess.allowsLLMFeatures
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case textTransformations(TextTransformationFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions
  @Dependency(\.hexToolServer) var hexToolServer

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Scope(state: \.textTransformations, action: \.textTransformations) {
      TextTransformationFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
        
      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring(),
          prewarmToolServer()
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          await pasteboard.paste(lastTranscript)
        }
        
      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to settings")
        state.activeTab = .settings
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .settings:
        return .none

      case .textTransformations:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			if tab == .transformations, !state.allowsLLMFeatures {
				return .none
			}
			state.activeTab = tab
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case .requestMicrophone:
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .requestAccessibility:
        return .run { send in
          await permissions.requestAccessibility()
          // Trigger permission refresh and use smart retry with exponential backoff
          permissions.triggerPermissionRefresh()
          await smartPermissionRetry(send: send, checkFor: .accessibility)
        }

      case .requestInputMonitoring:
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          permissions.triggerPermissionRefresh()
          await smartPermissionRetry(send: send, checkFor: .inputMonitoring)
        }

      case .modelStatusEvaluated:
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        do {
          try await Task.sleep(nanoseconds: .max)
        } catch {
          // Expected on cancellation
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor permission change events (includes app activation + accessibility notifications)
      for await change in permissions.observePermissionChanges() {
        switch change {
        case .appBecameActive:
          await send(.appActivated)
        case .accessibilityMayHaveChanged:
          await send(.checkPermissions)
        case .refreshRequested:
          await send(.checkPermissions)
        }
      }
    }
  }

  /// Smart retry with exponential backoff for permission checks.
  ///
  /// Instead of fixed 10x 1-second polling, this uses exponential backoff:
  /// - Starts at 200ms, doubles each time up to 2 seconds
  /// - Stops immediately when permission is granted
  /// - Caps total time at ~30 seconds
  private enum PermissionToCheck {
    case accessibility
    case inputMonitoring
  }

  private func smartPermissionRetry(send: Send<Action>, checkFor permission: PermissionToCheck) async {
    var delay: UInt64 = 200_000_000 // Start at 200ms
    let maxDelay: UInt64 = 2_000_000_000 // Cap at 2 seconds
    let maxAttempts = 12 // ~30 seconds total with exponential backoff

    for _ in 0..<maxAttempts {
      try? await Task.sleep(nanoseconds: delay)

      // Check current status
      let status: PermissionStatus
      switch permission {
      case .accessibility:
        status = permissions.accessibilityStatus()
      case .inputMonitoring:
        status = permissions.inputMonitoringStatus()
      }

      await send(.checkPermissions)

      // Stop early if permission was granted
      if status == .granted {
        return
      }

      // Exponential backoff with cap
      delay = min(delay * 2, maxDelay)
    }
  }

  private func prewarmToolServer() -> Effect<Action> {
    .run { _ in
      _ = try? await hexToolServer.ensureServer(nil)
    }
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.settings)

        if store.allowsLLMFeatures {
          Button {
            store.send(.setActiveTab(.transformations))
          } label: {
            Label("Transformations", systemImage: "wand.and.stars")
          }
          .buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.transformations)
        }

        Button {
          store.send(.setActiveTab(.history))
        } label: {
          Label("History", systemImage: "clock")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.history)

        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.about)
      }
    } detail: {
      switch store.activeTab {
      case .settings:
        SettingsView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission,
          allowsLLMFeatures: store.allowsLLMFeatures
        )
        .navigationTitle("Settings")
      case .transformations:
        if store.allowsLLMFeatures {
          TextTransformationView(store: store.scope(state: \.textTransformations, action: \.textTransformations))
            .navigationTitle("Text Transformations")
        } else {
          SettingsView(
            store: store.scope(state: \.settings, action: \.settings),
            microphonePermission: store.microphonePermission,
            accessibilityPermission: store.accessibilityPermission,
            inputMonitoringPermission: store.inputMonitoringPermission,
            allowsLLMFeatures: store.allowsLLMFeatures
          )
          .navigationTitle("Settings")
        }
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .enableInjection()
  }
}
