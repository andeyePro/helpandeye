import HelpAndICore
import MessageUI
import SwiftUI

/// The caller's screen: three buttons, and a plain statement of what has happened to the last
/// call. It never says help is coming unless a responder has acknowledged (decision 6).
struct CallView: View {
    @EnvironmentObject var model: AppModel
    @State private var composingSMS = false

    var body: some View {
        VStack(spacing: 16) {
            if let r = model.current { StatusCard(request: r, composingSMS: $composingSMS) }
            Spacer(minLength: 0)
            Button { model.press(.red) } label: {
                Text("Come now").font(.system(size: 40, weight: .bold)).frame(maxWidth: .infinity, minHeight: 220)
            }
            .buttonStyle(CallButtonStyle(colour: .red))
            .accessibilityHint("Calls your responders to come now")
            HStack(spacing: 16) {
                Button { model.press(.amber) } label: {
                    Text("Come when convenient").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 90)
                }
                .buttonStyle(CallButtonStyle(colour: .amber))
                Button { model.press(.green) } label: {
                    Text("I'm OK now").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 90)
                }
                .buttonStyle(CallButtonStyle(colour: .green))
            }
            if let r = model.current, r.colour != .green, r.status != .notSent {
                FollowUps(request: r)
            }
            NotA999Notice()
        }
        .padding()
        .sheet(isPresented: $composingSMS) {
            if let r = model.current {
                SMSComposer(recipients: model.group?.members.filter(\.canRespond).compactMap(\.phone) ?? [],
                            body: RoutePlan.smsBody(for: r))
            }
        }
    }
}

struct CallButtonStyle: ButtonStyle {
    let colour: Colour
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .background(colour.color.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    let request: OutgoingRequest
    @Binding var composingSMS: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if request.status == .notSent {
                    Image(systemName: "xmark").font(.title.bold()).foregroundStyle(.red).accessibilityLabel("Not sent")
                }
                Text(headline).font(.title3.bold())
            }
            Text("\(request.colour.label), \(request.createdAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
            ForEach(Route.allCases.filter { request.routes[$0] != nil }, id: \.self) { route in
                Text(line(route)).font(.footnote).foregroundStyle(.secondary)
            }
            if request.status == .notSent {
                HStack {
                    Button("Try again") { model.press(request.colour) }.buttonStyle(.borderedProminent)
                    if RoutePlan.offerManualSMS(for: request, smsAvailable: MFMessageComposeViewController.canSendText(), smsIsAutomatic: false) {
                        Button("Send as a text") { composingSMS = true }.buttonStyle(.bordered)
                    }
                }
                Text("If you need help now, call 999.").font(.callout.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch request.status {
        case .sending: "Sending…"
        case .waitingForResponder: "Sent. Waiting for a responder to see it."
        case let .seen(who): "\(model.name(ofMember: who)) has seen your call."
        case .notSent: "Not sent. Nobody has been told."
        }
    }

    private func line(_ route: Route) -> String {
        let name = switch route { case .internet: "Internet"; case .sms: "Text message"; case .mesh: "Local radio" }
        switch request.routes[route] {
        case .sending?: return "\(name): sending"
        case .sent?: return "\(name): sent"
        case let .failed(why)?: return "\(name): not sent (\(why))"
        case nil: return ""
        }
    }
}

struct FollowUps: View {
    @EnvironmentObject var model: AppModel
    let request: OutgoingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell them more (optional)").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                ForEach(CallCategory.allCases, id: \.self) { c in
                    Button(c.label) { model.add(c) }
                        .buttonStyle(.bordered)
                        .disabled(request.categories.contains(c))
                }
            }
        }
    }
}

struct SMSComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ c: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            c.dismiss(animated: true)
        }
    }
}
