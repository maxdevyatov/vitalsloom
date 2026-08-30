import SwiftUI

struct SafetyNoticeView: View {
    let accept: () -> Void
    @State private var understandsLimitations = false
    @State private var understandsIndependence = false

    var body: some View {
        ZStack {
            Color(red: 0.018, green: 0.025, blue: 0.027).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg.rectangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VITALSLOOM").font(.title.bold())
                        Text("Important information before monitoring").foregroundStyle(.secondary)
                    }
                }

                notice(
                    icon: "cross.case.fill",
                    title: "Not a medical device",
                    text: "VitalsLoom is an unofficial personal data display. It is not intended for diagnosis, treatment, emergency decisions, or any situation where delayed, inaccurate, missing, or failed readings or alarms could cause harm.")
                notice(
                    icon: "bell.slash.fill",
                    title: "Alarms can fail",
                    text: "Connectivity, the data source, macOS, sleep, audio output, application errors, or configuration can delay or prevent readings and alerts. Maintain direct supervision and use an appropriate certified monitor when medical monitoring is needed.")
                notice(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Independent compatibility",
                    text: "VitalsLoom is not affiliated with, sponsored by, or endorsed by Owlet Baby Care, Inc. Use it only with hardware and an account you own or are authorized to access. The unofficial integration may change or stop working.")

                Divider()
                Toggle("I understand that VitalsLoom is not a medical device and must not be relied upon for safety or medical decisions.", isOn: $understandsLimitations)
                Toggle("I understand that this is independent, unofficial software and is not endorsed by the device manufacturer.", isOn: $understandsIndependence)

                HStack {
                    Text("Provided “as is” without warranty under the MIT License.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue", action: accept)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!understandsLimitations || !understandsIndependence)
                }
            }
            .padding(28)
            .frame(maxWidth: 760)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
            .padding(30)
        }
    }

    private func notice(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
