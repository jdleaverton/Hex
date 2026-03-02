import Combine
import ComposableArchitecture
#if DEBUG
import Inject
#endif
import Sparkle
import SwiftUI

@Observable
@MainActor
final class CheckForUpdatesViewModel {
	init() {
		anyCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
			.sink(receiveValue: { self.canCheckForUpdates = $0 })
	}

	static let shared = CheckForUpdatesViewModel()

	let controller = SPUStandardUpdaterController(
		startingUpdater: true,
		updaterDelegate: nil,
		userDriverDelegate: nil
	)

	var anyCancellable: AnyCancellable?

	var canCheckForUpdates = false

	func checkForUpdates() {
		controller.updater.checkForUpdates()
	}
}

struct CheckForUpdatesView: View {
	@State var viewModel = CheckForUpdatesViewModel.shared
#if DEBUG
	@ObserveInjection var inject
#endif

	var body: some View {
		Button("Check for Updates…", action: viewModel.checkForUpdates)
			.disabled(!viewModel.canCheckForUpdates)
#if DEBUG
			.enableInjection()
#endif
	}
}
