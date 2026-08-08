import SwiftUI

// MARK: - Message

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(message.role == .user ? "You" : "Iris")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(message.role == .user ? .blue : .purple)
                if message.isStreaming {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
            }

            if !message.text.isEmpty {
                MarkdownText(raw: message.text)
            }

            ForEach(message.toolCalls) { call in
                ToolCallRow(call: call)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(message.role == .user ? Color.primary.opacity(0.04) : .clear)
    }
}

// MARK: - Markdown + code blocks

/// Splits fenced code blocks out and renders the prose through SwiftUI's own markdown
/// parsing. Not a full markdown engine — Phase 2 is deliberately plain; this exists so code
/// is readable and copyable, which is most of the value.
struct MarkdownText: View {
    let raw: String

    private enum Segment: Identifiable {
        case prose(String), code(language: String, body: String)
        var id: String {
            switch self {
            case .prose(let s): return "p" + s.prefix(24)
            case .code(_, let b): return "c" + b.prefix(24)
            }
        }
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var inCode = false
        var language = ""
        var buffer: [String] = []

        func flush() {
            let joined = buffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(inCode ? .code(language: language, body: joined) : .prose(joined))
            }
            buffer.removeAll()
        }

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                if !inCode { language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                switch segment {
                case .prose(let text):
                    Text(attributed(text))
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                case .code(let language, let body):
                    CodeBlock(language: language, code: body)
                }
            }
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        // .inlineOnlyPreservingWhitespace keeps newlines, which the full parser strips.
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "copied" : "copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

// MARK: - Tool calls

struct ToolCallRow: View {
    let call: ToolCall
    @State private var expanded = false

    private var icon: String {
        if call.deniedInput != nil { return "hand.raised.fill" }
        if call.isError { return "exclamationmark.triangle.fill" }
        if call.result == nil { return "circle.dotted" }
        return "checkmark.circle.fill"
    }

    private var tint: Color {
        if call.deniedInput != nil { return .orange }
        if call.isError { return .red }
        if call.result == nil { return .secondary }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(tint).font(.system(size: 10))
                    Text(call.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(call.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                if let denied = call.deniedInput {
                    // Phase 5 renders this as a real diff with an approve action. Phase 2
                    // just proves the payload is here.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Blocked — approval required", systemImage: "lock.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                        ForEach(denied.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            Text("\(k): \(v.prefix(400))")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                } else if let result = call.result {
                    Text(result.prefix(2000))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(.leading, 2)
    }
}
