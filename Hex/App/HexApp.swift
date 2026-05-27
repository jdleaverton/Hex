import ComposableArchitecture
#if DEBUG
import Inject
#endif
import Sparkle
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
    var body: some Scene {
        MenuBarExtra {
            CheckForUpdatesView()

            // Copy last transcript to clipboard
            MenuBarCopyLastTranscriptButton()

            Divider()

            // Call recording toggle
            MenuBarCallRecordingButton(
                store: Self.appStore.scope(state: \.callRecording, action: \.callRecording)
            )

            Divider()

            Button("Settings...") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")
			
			Divider()
			
			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			let image: NSImage = {
				let ratio = $0.size.height / $0.size.width
				$0.size.height = 18
				$0.size.width = 18 / ratio
				return $0
			}(NSImage(named: "HexIcon")!)
			Image(nsImage: image)
		}


		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}

				CommandGroup(replacing: .help) {}
			}
	}
}
