import CoreLocation
import helpandeyeCore
import MessageUI
import SwiftUI

/// The caller's screen: three buttons, and a plain statement of what has happened to the last
/// call. It never says help is coming unless a responder has acknowledged (decision 6).
struct CallView: View {
    @EnvironmentObject var model: AppModel
    @State private var composingSMS = false
    @AppStorage(ShareEveryCall.key) private var shareEveryCall = false
    @StateObject private var location = OneShotLocation()

    var body: some View {
        NavigationStack {
            ScrollView {
                content.padding()
                    // A tap on any empty part of the screen puts the keyboard away.
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { hideKeyboard() })
            }
            .keyboardDismissable()
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $composingSMS) {
            if let r = model.current {
                SMSComposer(recipients: RoutePlan.smsRecipients(in: model.group, me: model.saved?.me),
                            body: RoutePlan.smsBody(for: r))
            }
        }
    }

    /// Red and amber also send where the caller is, if they chose that.
    private func press(_ colour: Colour) {
        model.press(colour)
        if shareEveryCall, colour != .green, model.canSendPersonal {
            location.find { model.sharePosition(latitude: $0, longitude: $1, accuracy: $2) }
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            if let r = model.current { StatusCard(request: r, composingSMS: $composingSMS) }
            Button { press(.red) } label: {
                // Scales with the reader's text size, shrinking only if it would not fit.
                Text("Come now").font(.largeTitle.weight(.heavy)).minimumScaleFactor(0.5).frame(maxWidth: .infinity, minHeight: 220)
            }
            .buttonStyle(CallButtonStyle(colour: .red))
            .accessibilityHint("Asks your responders to come now")
            // Side by side when they fit; one above the other at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { amber; green }
                VStack(spacing: 16) { amber; green }
            }
            if let r = model.current, r.colour != .green, r.status != .notSent {
                FollowUps(request: r)
            }
            NotA999Notice()
        }
    }
}

/// The caller's choice to send where they are with every red or amber call. Kept on this phone.
enum ShareEveryCall {
    static let key = "shareEveryCall"
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension CallView {
    private var amber: some View {
        Button { press(.amber) } label: {
            Text("Come when convenient").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(CallButtonStyle(colour: .amber))
        .accessibilityHint("Asks your responders to come when they can")
    }

    private var green: some View {
        Button { press(.green) } label: {
            Text("I'm OK now").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(CallButtonStyle(colour: .green))
        .accessibilityHint("Tells your responders you are all right")
    }
}

struct CallButtonStyle: ButtonStyle {
    let colour: Colour
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(colour.onColor)
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
                if words.cross {
                    Image(systemName: "xmark").font(.title.bold()).foregroundStyle(Color.warning).accessibilityLabel("Not sent")
                }
                Text(headline).font(.title3.bold())
            }
            Text("\(request.colour.label), \(request.createdAt.formatted(date: .omitted, time: .shortened))")
            ForEach(Route.allCases.filter { request.routes[$0] != nil }, id: \.self) { route in
                Text(line(route))
            }
            if request.status == .notSent {
                HStack {
                    Button("Try again") { model.press(request.colour) }.buttonStyle(.action)
                    if RoutePlan.offerManualSMS(for: request, smsAvailable: MFMessageComposeViewController.canSendText(), smsIsAutomatic: false,
                                                recipients: RoutePlan.smsRecipients(in: model.group, me: model.saved?.me)) {
                        Button("Send as a text") { composingSMS = true }.buttonStyle(.secondaryAction)
                    }
                }
                if words.call999 { Text("If you need help now, call 999.").font(.callout.bold()) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        // Solid, not see-through: words over a blurred background lose contrast.
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        // Someone who cannot see the screen hears each change, such as a responder seeing the call.
        .onChange(of: headline) { _, new in UIAccessibility.post(notification: .announcement, argument: new) }
    }

    private var words: StatusWords.Words { StatusWords.phone(request.status, name: model.name(ofMember:)) }
    private var headline: String { words.headline }

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
    @State private var typed = ""
    @State private var problem: String?
    @FocusState private var typing: Bool
    @StateObject private var location = OneShotLocation()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tell them more (optional)").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                ForEach(CallCategory.choices, id: \.self) { c in
                    let chosen = request.categories.contains(c)
                    // Pressed again, a choice is taken back: one pressed by mistake is not stuck.
                    Button {
                        if chosen { model.withdraw(c); return }
                        model.add(c)
                        // "Something else" asks what: the keyboard's microphone takes speech too.
                        if c == .other, model.canSendPersonal { typing = true }
                    } label: {
                        Label(c.label, systemImage: chosen ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(ActionButtonStyle(prominent: chosen))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityHint(chosen ? "Tells your responders to ignore this" : "Tells your responders")
                }
            }
            if model.canSendPersonal {
                HStack(alignment: .bottom) {
                    TextField("Type or speak a short message", text: $typed, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit(sendNote)
                    Button("Send", action: sendNote).buttonStyle(.action)
                }
                Button {
                    location.find { model.sharePosition(latitude: $0, longitude: $1, accuracy: $2) }
                } label: {
                    Label(location.state == .finding ? "Finding where you are…" : "Share where I am", systemImage: "location.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.secondaryAction)
                .disabled(location.state == .finding)
                if location.state == .shared { Text("Where you are was sent.") }
                if location.state == .denied { Text("Help&I is not allowed to use your location. You can allow it in Settings.") }
                ForEach(request.notes, id: \.self) { Text("You said: \($0)") }
            } else {
                Text("Typed messages and where you are can only go over the internet or your box, and neither is working now.")
            }
            if let problem { Text(problem) }
        }
    }
}

extension FollowUps {
    private func sendNote() {
        guard !typed.isEmpty else { return }
        problem = model.addNote(typed)
        typed = ""
    }
}

/// One location fix, only when the caller asks for it.
@MainActor
final class OneShotLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State { case idle, finding, shared, denied }
    @Published private(set) var state = State.idle
    private let manager = CLLocationManager()
    private var done: ((Double, Double, Double) -> Void)?

    func find(_ done: @escaping (Double, Double, Double) -> Void) {
        self.done = done
        state = .finding
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            guard self.state == .finding else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.state = .denied
            default: break
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            self.done?(l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy)
            self.done = nil
            self.state = .shared
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.state = (error as? CLError)?.code == .denied ? .denied : .idle }
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
