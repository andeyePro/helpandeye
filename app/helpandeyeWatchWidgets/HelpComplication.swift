import SwiftUI
import WidgetKit

/// The Help complication, in every shape a watch face offers. Tapping it opens Help&I's 60-second
/// countdown (app spec, Watch app). It never shows anything about a call, so it can never look as
/// if help is on its way.
@main
struct HelpComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "help", provider: Always()) { _ in Face() }
            .configurationDisplayName("Help")
            .description("Starts a 60-second countdown, then calls for help. Press I'm OK to stop it.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

/// The complication never changes.
struct Always: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

struct Entry: TimelineEntry { let date: Date }

struct Face: View {
    @Environment(\.widgetFamily) private var family
    private let symbol = Image(systemName: "hand.raised.fill")

    var body: some View {
        shape
            .widgetURL(URL(string: "helpandeye://countdown"))
            .containerBackground(Color(red: 0xC0 / 255, green: 0x10 / 255, blue: 0x1A / 255), for: .widget)
            .accessibilityLabel("Help: starts a 60-second countdown, then calls for help")
    }

    @ViewBuilder private var shape: some View {
        switch family {
        case .accessoryInline: Label("Help", systemImage: "hand.raised.fill")
        case .accessoryCorner: symbol.font(.title2.bold()).widgetLabel("Help")
        case .accessoryRectangular:
            HStack {
                symbol.font(.title.bold())
                Text("Help").font(.title2.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    symbol.font(.title3.bold())
                    Text("Help").font(.caption2.bold())
                }
            }
        }
    }
}
