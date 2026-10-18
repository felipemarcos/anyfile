import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(AppSettings.self) private var settings
    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var selection = Set<ConversionJob.ID>()

    var body: some View {
        VStack(spacing: 0) {
            if queue.jobs.isEmpty {
                EmptyDropView(isTargeted: isTargeted) { isImporting = true }
            } else {
                List(selection: $selection) {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job)
                    }
                }
                // Delete / Forward Delete (and Edit > Delete) remove the selected files.
                .onDeleteCommand(perform: removeSelected)
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard !selection.isEmpty else { return .ignored }
                    removeSelected()
                    return .handled
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
                Divider()
                BottomBar(addFiles: { isImporting = true })
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFiles)) { _ in isImporting = true }
        .navigationTitle("AnyFile")
        .navigationSubtitle(queue.jobs.isEmpty ? "" : "\(queue.jobs.count) file\(queue.jobs.count == 1 ? "" : "s")")
    }

    private func removeSelected() {
        queue.remove(ids: selection)
        selection.removeAll()
    }
}

private struct EmptyDropView: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text("Drop files to convert")
                .font(.title2.weight(.semibold))
            Text("Images, audio, video, documents, PDFs, CSV, Excel and JSON.\nEverything is converted on this Mac. Nothing is uploaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…", action: choose)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                )
                .padding(20)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

private struct BottomBar: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(AppSettings.self) private var settings
    let addFiles: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: addFiles) {
                Label("Add Files", systemImage: "plus")
            }
            Button("Clear", action: queue.clear)
                .disabled(queue.isConverting)

            Spacer()

            Label(destinationText, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Change in Settings (⌘,)")

            let common = queue.commonTargets
            Menu("Set All To") {
                ForEach(FormatCategory.allCases, id: \.self) { category in
                    let formats = common.filter { $0.category == category }
                    if !formats.isEmpty {
                        Section(category.rawValue) {
                            ForEach(formats) { format in
                                Button(format.displayName) { queue.setTargetForAll(format) }
                            }
                        }
                    }
                }
            }
            .fixedSize()
            .disabled(common.isEmpty || queue.isConverting)

            if queue.isConverting {
                Button("Stop", role: .cancel, action: queue.cancel)
            } else {
                Button("Convert") { queue.start(settings: settings) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!queue.jobs.contains { $0.canConvert && !$0.isDone })
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var destinationText: String {
        settings.outputFolder.map { "Saving to \($0.lastPathComponent)" } ?? "Saving next to originals"
    }
}

extension ConversionJob {
    var isDone: Bool {
        if case .done = status { return true }
        return false
    }
}
