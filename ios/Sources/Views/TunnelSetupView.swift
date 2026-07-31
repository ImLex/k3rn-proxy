import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Guided self-serve tunnel setup. Provisions this device's WireGuard peer and
/// presents an importable config (QR for the WireGuard app, or a shared .conf).
/// The two steps iOS won't let an app automate — trusting the crew certificate
/// and enabling the tunnel — are spelled out as a checklist.
struct TunnelSetupView: View {
    @State private var phase: Phase = .loading
    @State private var showShare = false

    enum Phase {
        case loading
        case ready(WireGuardTunnel)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                introCard
                switch phase {
                case .loading:
                    ProgressView("Provisioning your tunnel…")
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                case .ready(let tunnel):
                    qrCard(tunnel)
                    stepsCard
                case .failed(let msg):
                    ErrorBanner(message: msg)
                    Button("Try again") { Task { await load() } }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Connect device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do { phase = .ready(try await TunnelService.provision()) }
        catch { phase = .failed(AppError.map(error).errorDescription ?? "Provisioning failed") }
    }

    // MARK: cards

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Personal VPN tunnel")
            Text("Routes only HackEx traffic through the crew proxy so your captures sync here. Works on Wi-Fi and cellular. Your tunnel key is generated on this device and never leaves it.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }

    private func qrCard(_ tunnel: WireGuardTunnel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "1. Add the tunnel")
            Text("In the WireGuard app tap **+ → Create from QR code** and scan this:")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            if let img = Self.qrImage(from: tunnel.confText) {
                Image(uiImage: img)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).frame(maxWidth: .infinity)
                    .padding(10).background(Color.white).cornerRadius(12)
            }
            DetailRow(label: "Tunnel IP") {
                Text(tunnel.assignedIP).font(.mono(14)).foregroundStyle(Theme.textPrimary)
            }
            Button {
                showShare = true
            } label: {
                Label("Or share the config file", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [Self.confFileURL(tunnel.confText)])
            }
        }
        .cardStyle()
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "2. Finish in Settings")
            step("Install the crew certificate and enable full trust (Settings → General → VPN & Device Management, then Certificate Trust Settings). See the setup guide on Discord.")
            step("Turn the tunnel ON in the WireGuard app.")
            step("Open HackEx with the tunnel on — your profile and targets start syncing.")
        }
        .cardStyle()
    }

    private func step(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5))
                .foregroundStyle(Theme.textFaint).padding(.top, 6)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: helpers

    private static func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        let ctx = CIContext()
        guard let out = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func confFileURL(_ text: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("K3RN.conf")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}

/// UIActivityViewController bridge for sharing the `.conf` into WireGuard.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
