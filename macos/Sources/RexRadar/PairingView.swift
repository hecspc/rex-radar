import CoreImage.CIFilterBuiltins
import SwiftUI

/// The window's "iPhone & iPad" page: a pairing QR code per address this Mac has.
struct PairingView: View {
  @ObservedObject var hub: HubServer

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Connect iPhone & iPad").font(.title2.weight(.bold))
          Text(
            "Scan a code with the iPhone or iPad camera to open Rex Radar there and pair it with this Mac. "
              + "Taps on the phone open agents here, in this Mac's Rex."
          )
          .foregroundStyle(.secondary)
          Label("Hub \(hub.state) · port \(HubServer.port)", systemImage: "antenna.radiowaves.left.and.right")
            .font(.caption).foregroundStyle(.secondary)
        }
        GlassEffectContainer(spacing: 16) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
            ForEach(sortedAddresses, id: \.self) { address in
              GlassCard(padding: 16) {
                VStack(spacing: 10) {
                  if let url = hub.pairingURL(host: address), let image = QRCode.image(for: url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                      .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10))
                  }
                  Text(address).font(.headline.monospaced())
                  Text(label(for: address)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
              }
            }
          }
        }
        Text("Token: \(hub.token)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }
      .padding(24)
    }
    .navigationTitle("iPhone & iPad")
  }

  /// Tailscale first: it reaches the Mac from anywhere, encrypted.
  private var sortedAddresses: [String] {
    hub.addresses.sorted { (isTailscale($0) ? 0 : 1, $0) < (isTailscale($1) ? 0 : 1, $1) }
  }

  private func isTailscale(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { Int($0) }
    return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
  }

  private func label(for ip: String) -> String { isTailscale(ip) ? "Tailscale · anywhere" : "Local network" }
}

enum QRCode {
  static func image(for text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}
