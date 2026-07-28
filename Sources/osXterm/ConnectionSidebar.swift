import OsXTermCore
import SwiftUI

struct ConnectionSidebar: View {
    let profiles: [SSHProfile]
    let connectedProfileIDs: Set<UUID>
    @Binding var selectedProfileID: SSHProfile.ID?
    let onConnect: (SSHProfile) -> Void
    let onEdit: (SSHProfile) -> Void
    let onDuplicate: (SSHProfile) -> Void
    let onDelete: (SSHProfile) -> Void

    @State private var searchText = ""

    private var visibleProfiles: [SSHProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { profile in
            [profile.name, profile.username, profile.host].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var body: some View {
        List(selection: $selectedProfileID) {
            Section {
                ForEach(visibleProfiles) { profile in
                    ConnectionRow(
                        profile: profile,
                        isConnected: connectedProfileIDs.contains(profile.id),
                        onDelete: { onDelete(profile) }
                    )
                    .tag(profile.id)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedProfileID = profile.id }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedProfileID = profile.id
                            onConnect(profile)
                        }
                    )
                    .contextMenu {
                        Button("Connect") { onConnect(profile) }
                        Button("Edit") { onEdit(profile) }
                        Button("Duplicate") { onDuplicate(profile) }
                        Divider()
                        Button("Delete", role: .destructive) { onDelete(profile) }
                    }
                }
            } header: {
                if visibleProfiles.isEmpty {
                    Text(searchText.isEmpty ? "No connections yet" : "No matching connections")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.background)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    }
}

private struct ConnectionRow: View {
    let profile: SSHProfile
    let isConnected: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).lineLimit(1)
                    Text(endpointText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "server.rack")
                    .foregroundStyle(isConnected ? Color.green : Color.accentColor)
            }
            Spacer(minLength: 4)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(profile.name)")
            .help("Delete connection")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name), \(endpointText), \(isConnected ? "Connected" : "Not connected")")
    }

    private var endpointText: String {
        let target = SSHConnectionTarget.parse(host: profile.host, username: profile.username)
            ?? SSHConnectionTarget(username: profile.username, host: profile.host)
        return "\(target.username)@\(target.host):\(profile.port)"
    }
}
