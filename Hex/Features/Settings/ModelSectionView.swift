import ComposableArchitecture
#if DEBUG
import Inject
#endif
import SwiftUI

struct ModelSectionView: View {
#if DEBUG
	@ObserveInjection var inject
#endif
	@Bindable var store: StoreOf<SettingsFeature>
	let shouldFlash: Bool

	var body: some View {
		Section("Transcription Model") {
			ModelDownloadView(
				store: store.scope(state: \.modelDownload, action: \.modelDownload),
				shouldFlash: shouldFlash
			)
		}
#if DEBUG
	.enableInjection()
#endif
	}
}
