import AppKit
import SwiftUI

struct JobRow: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(AppSettings.self) private var settings
    @Bindable var job: ConversionJob
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.input.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.input.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }

            Spacer(minLength: 12)

            if !job.availableTargets.isEmpty {
                HStack(spacing: 6) {
                    Text(job.source?.displayName ?? "")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Picker("Convert to", selection: $job.target) {
                        ForEach(FormatCategory.allCases, id: \.self) { category in
                            let formats = job.availableTargets.filter { $0.category == category }
                            if !formats.isEmpty {
                                Section(category.rawValue) {
                                    ForEach(formats) { format in
                                        Text(format.displayName).tag(Optional(format))
                                    }
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(job.isRunning)
                    .onChange(of: job.target) {
                        if job.isDone { job.status = .pending }
                    }
                }
            }

            trailingButton
                .frame(width: 22)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Convert This File") { queue.start(only: [job], settings: settings) }
                .disabled(!job.canConvert || queue.isConverting)
            if case .done(let url) = job.status {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open") { NSWorkspace.shared.open(url) }
            }
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.input]) }
            Divider()
            Button("Remove", role: .destructive) { queue.remove(job) }
                .disabled(job.isRunning)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .pending:
            Text(job.input.deletingLastPathComponent().path(percentEncoded: false).abbreviatingHome)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        case .running(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
        case .done(let url):
            Label("Saved as \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        case .unsupported:
            Label(job.source == nil ? "Unknown file type" : "No conversions available for \(job.source!.displayName)",
                  systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if case .done(let url) = job.status {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        } else if isHovering && !job.isRunning {
            Button {
                queue.remove(job)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove")
        } else {
            Color.clear
        }
    }
}

private extension String {
    var abbreviatingHome: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
