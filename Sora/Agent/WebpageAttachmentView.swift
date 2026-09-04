import SwiftUI

struct WebpageAttachmentView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader: WebpageLoader
    @State private var address: String
    let providerName: String
    let attach: (WebpageAttachment) -> Void

    init(page: WebpageAttachment?, providerName: String, attach: @escaping (WebpageAttachment) -> Void) {
        _loader = StateObject(wrappedValue: WebpageLoader(page: page))
        _address = State(initialValue: page?.url.absoluteString ?? "")
        self.providerName = providerName
        self.attach = attach
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attach webpage").font(.title2.weight(.semibold))
            Text("Fetch a page and review the text before adding it to your question.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("https://example.com", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Webpage address")
                    .onSubmit { loader.fetch(address) }
                    .onChange(of: address) { _ in loader.reset() }
                Button("Fetch Page") { loader.fetch(address) }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loader.isLoading)
            }
            if loader.isLoading {
                HStack {
                    ProgressView("Fetching page…").controlSize(.small)
                    Spacer()
                    Button("Stop Fetching") { loader.reset() }
                }
            }
            if let error = loader.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let page = loader.page {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title).font(.headline)
                    Text(page.url.absoluteString).font(.caption).textSelection(.enabled)
                    Text(page.isExcerpt ? "Excerpt • first \(page.text.utf8.count.formatted()) bytes" : "\(page.text.count.formatted()) characters")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(page.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Webpage preview")
            } else {
                Text("Public HTML and text pages are supported. Pages that need sign-in or JavaScript may have little readable text.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            Text("Fetching contacts the website. This text and its source will be sent to \(providerName) only when you send your question, and saved in this conversation.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Attach to Question") {
                    if let page = loader.page { attach(page); dismiss() }
                }
                .disabled(loader.page == nil || loader.isLoading)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .onDisappear { loader.reset() }
    }
}
