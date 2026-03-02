import SwiftUI
#if DEBUG
import Inject
#endif
import MarkdownUI

struct ChangelogView: View {
#if DEBUG
    @ObserveInjection var inject
#endif
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Changelog")
                    .font(.title)
                    .padding(.bottom, 10)

                if let changelogPath = Bundle.main.path(forResource: "changelog", ofType: "md"),
                    let changelogContent = try? String(
                        contentsOfFile: changelogPath, encoding: .utf8)
                {
                    Markdown(changelogContent)
                } else {
                    Text("Changelog could not be loaded.")
                        .foregroundColor(.red)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 20)
            }
            .padding()
        }
#if DEBUG
        .enableInjection()
#endif
    }
}
