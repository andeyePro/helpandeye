import CoreImage.CIFilterBuiltins
import SwiftUI
import helpandeyeCore
import VisionKit

struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().accessibilityLabel("Joining code")
        }
    }

    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "L"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Scans a joining code with the camera, or takes one pasted from a message.
struct CodeReader: View {
    let prompt: String
    let onCode: (String) -> Void
    @State private var pasted = ""
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt).font(.headline)
            if DataScannerViewController.isSupported {
                Button("Scan with the camera") { scanning = true }.buttonStyle(.action)
            }
            TextField("Or paste the code here", text: $pasted, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("Use pasted code") { if !pasted.isEmpty { onCode(pasted) } }
        }
        .sheet(isPresented: $scanning) {
            Scanner { code in scanning = false; onCode(code) }.ignoresSafeArea()
        }
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(b) in items {
                if let v = b.payloadStringValue, v.hasPrefix(Joining.prefix), !done { done = true; onCode(v) }
            }
        }
    }
}
