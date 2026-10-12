import ReaderCore
import SwiftUI

/// "Continue on p. 120 — from Mac, 2 hours ago": another device read further (or elsewhere) in this book.
struct RemotePositionPill: View {
    let position: SyncedPosition
    let current: String
    let onGo: () -> Void
    let onStay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Continue on \(position.label)?").font(.callout.weight(.medium))
                Text("From \(position.device), \(position.updated.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Go", action: onGo).buttonStyle(.borderedProminent).controlSize(.small)
            Button("Stay on \(current)", action: onStay).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remotePosition")
    }
}
