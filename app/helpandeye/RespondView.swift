import helpandeyeCore
import SwiftUI

/// The responder's list. A request leaves the top of the list only when a person acknowledges
/// it; nothing here closes, expires or acknowledges on its own (decision 6).
struct RespondView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                let groups = model.engines.filter { $0.me?.canRespond == true }
                if groups.allSatisfy({ $0.activity.inbox.requests.isEmpty }) {
                    Text("No calls for help.")
                }
                // One list per group, each under its name when there is more than one.
                ForEach(groups, id: \.identityKey) { e in
                    if groups.count > 1, !e.activity.inbox.requests.isEmpty {
                        Section(header: Header(e.group?.name ?? "Group")) {
                            ForEach(e.activity.inbox.sorted) { r in RequestRow(engine: e, request: r) }
                        }
                    } else {
                        ForEach(e.activity.inbox.sorted) { r in RequestRow(engine: e, request: r) }
                    }
                }
            }
            .navigationTitle("Respond")
            .keyboardDismissable()
        }
    }
}

struct RequestRow: View {
    let engine: HelpEngine
    let request: IncomingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill((request.colour ?? .red).color).frame(width: 18, height: 18)
                Text(engine.name(ofUnit: request.key.unit)).font(.title3.bold())
                Spacer()
                Text(request.firstHeardAt, style: .relative)
            }
            Text(request.colour.map { ButtonWords.words($0, in: engine.group) } ?? "Call for help (details still arriving)")
            ForEach(request.orderedCategories, id: \.self) { Text("• \(ButtonWords.words($0, in: engine.group))") }
            ForEach(request.orderedNotes, id: \.self) { Text("“\($0)”").italic() }
            if let p = request.position,
               let url = URL(string: "https://maps.apple.com/?ll=\(p.latitude),\(p.longitude)&q=Help%26I%20caller") {
                Link("Open their location in Maps (within \(Int(p.accuracy)) m)", destination: url)
            }
            Text("Heard by " + request.heardOn.map { $0 == .mesh ? "local radio" : ($0 == .internet ? "internet" : "text") }.sorted().joined(separator: " and "))
            if request.isAcknowledged {
                Text("Acknowledged by " + request.acknowledgedBy.map(engine.name(ofMember:)).joined(separator: ", "))
                    .font(.callout.bold())
            }
            switch engine.ackSendStatus(request.key) {
            case .sending?: Text("Sending your acknowledgement…")
            case .notSent?:
                HStack {
                    Image(systemName: "xmark").foregroundStyle(Color.warning).accessibilityLabel("Not sent")
                    Text("Your acknowledgement did not go out, so the caller has not seen it.")
                    Button("Try again") { engine.retryAck(request.key) }.buttonStyle(.secondaryAction)
                }
            default: EmptyView()
            }
            if !request.acknowledgedBy.contains(engine.saved?.me ?? 0) {
                Button { _ = engine.acknowledge(request.key) } label: {
                    Text("Acknowledge: \(CallerFeedback.acknowledgeWords)").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.action)
            }
        }
        .padding(.vertical, 6)
    }
}

extension HelpEngine {
    /// Tells engines apart in lists: each group's engine has its own saved group.
    var identityKey: ObjectIdentifier { ObjectIdentifier(self) }
}
