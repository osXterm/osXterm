import SwiftUI

struct AppSidebar: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var searchText = ""
    @State private var profilePendingDeletion: ProfilePresentation?
    @State private var folderPendingDeletion: FolderPresentation?
    @State private var folderEditorID: UUID?
    @State private var folderName = ""
    @State private var isFolderEditorPresented = false

    private var visibleProfiles: [ProfilePresentation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.snapshot.profiles }
        return model.snapshot.profiles.filter { profile in
            [profile.name, profile.host, profile.username, profile.tags.joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var favorites: [ProfilePresentation] {
        visibleProfiles.filter(\.isFavorite)
    }

    private var recentProfiles: [ProfilePresentation] {
        visibleProfiles
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        List(selection: $model.sidebarSelection) {
            if !favorites.isEmpty {
                Section(AppText.favorites) {
                    ForEach(favorites) { profile in
                        profileRow(profile)
                    }
                }
            }

            if !model.snapshot.folders.isEmpty {
                Section {
                    ForEach(model.snapshot.folders) { folder in
                        DisclosureGroup {
                            ForEach(profiles(in: folder)) { profile in
                                profileRow(profile)
                            }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                        .tag(AppSidebarSelection.folder(folder.id))
                        .accessibilityLabel(AppText.string("Folder \(folder.name)", korean: "폴더 \(folder.name)"))
                        .contextMenu {
                            Button(AppText.edit) { beginFolderEditor(folder) }
                            Button(AppText.delete, role: .destructive) { folderPendingDeletion = folder }
                        }
                    }
                } header: {
                    HStack {
                        Text(AppText.folders)
                        Spacer()
                        Button {
                            folderEditorID = nil
                            folderName = ""
                            isFolderEditorPresented = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(AppText.string("New folder", korean: "새 폴더"))
                        .disabled(!model.isServiceAvailable)
                    }
                }
            } else {
                Section {
                    Button {
                        folderEditorID = nil
                        folderName = ""
                        isFolderEditorPresented = true
                    } label: {
                        Label(AppText.string("New Folder", korean: "새 폴더"), systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.isServiceAvailable)
                } header: {
                    Text(AppText.folders)
                }
            }

            Section(AppText.profiles) {
                if visibleProfiles.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty
                            ? AppText.string("No saved connections", korean: "저장된 연결이 없습니다")
                            : AppText.string("No matching connections", korean: "일치하는 연결이 없습니다"),
                        systemImage: "server.rack",
                        description: Text(
                            searchText.isEmpty
                                ? AppText.string("Create a connection to begin.", korean: "연결을 만들어 시작하세요.")
                                : AppText.string("Try a different name, host or tag.", korean: "다른 이름, 호스트 또는 태그로 검색하세요.")
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(unassignedProfiles) { profile in
                        profileRow(profile)
                    }
                }
            }

            if !recentProfiles.isEmpty {
                Section(AppText.recent) {
                    ForEach(recentProfiles) { profile in
                        profileRow(profile, showsTags: false)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: AppText.string("Search connections", korean: "연결 검색")
        )
        .confirmationDialog(
            AppText.string("Delete this connection?", korean: "이 연결을 삭제할까요?"),
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: profilePendingDeletion
        ) { profile in
            Button(AppText.delete, role: .destructive) {
                model.deleteProfile(id: profile.id)
                profilePendingDeletion = nil
            }
            Button(AppText.cancel, role: .cancel) {
                profilePendingDeletion = nil
            }
        } message: { profile in
            Text(AppText.string(
                "\(profile.name) will be removed. Active connections cannot be deleted by the core service.",
                korean: "\(profile.name)을 삭제합니다. 활성 연결은 코어 서비스에서 삭제할 수 없습니다."
            ))
        }
        .sheet(isPresented: $isFolderEditorPresented) {
            FolderEditorSheet(
                title: folderEditorID == nil
                    ? AppText.string("New Folder", korean: "새 폴더")
                    : AppText.string("Rename Folder", korean: "폴더 이름 바꾸기"),
                name: $folderName,
                onSave: {
                    model.saveFolder(id: folderEditorID, name: folderName)
                    isFolderEditorPresented = false
                    folderName = ""
                    folderEditorID = nil
                },
                onCancel: {
                    isFolderEditorPresented = false
                    folderName = ""
                    folderEditorID = nil
                }
            )
        }
        .confirmationDialog(
            AppText.string("Delete this folder?", korean: "이 폴더를 삭제할까요?"),
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: folderPendingDeletion
        ) { folder in
            Button(AppText.delete, role: .destructive) {
                model.deleteFolder(id: folder.id)
                folderPendingDeletion = nil
            }
            Button(AppText.cancel, role: .cancel) { folderPendingDeletion = nil }
        } message: { folder in
            Text(AppText.string(
                "Profiles in \(folder.name) will remain saved without a folder.",
                korean: "\(folder.name)의 프로필은 삭제되지 않고 폴더 없이 남습니다."
            ))
        }
        .accessibilityLabel(AppText.string("Connection sidebar", korean: "연결 사이드바"))
    }

    @ViewBuilder
    private func profileRow(_ profile: ProfilePresentation, showsTags: Bool = true) -> some View {
        ProfileSidebarRow(profile: profile, showsTags: showsTags)
            .tag(AppSidebarSelection.profile(profile.id))
            .contentShape(Rectangle())
            .onTapGesture {
                model.sidebarSelection = .profile(profile.id)
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    model.connect(profileID: profile.id)
                }
            )
            .contextMenu {
                Button(AppText.connect) { model.connect(profileID: profile.id) }
                Button(AppText.edit) { model.editProfile(id: profile.id) }
                Button(AppText.duplicate) { model.duplicateProfile(id: profile.id) }
                Button(
                    profile.isFavorite
                        ? AppText.string("Remove from Favorites", korean: "즐겨찾기에서 제거")
                        : AppText.string("Add to Favorites", korean: "즐겨찾기에 추가")
                ) {
                    model.setFavorite(profileID: profile.id, isFavorite: !profile.isFavorite)
                }
                Divider()
                Button(AppText.delete, role: .destructive) {
                    profilePendingDeletion = profile
                }
            }
            .disabled(!model.isServiceAvailable)
    }

    private var unassignedProfiles: [ProfilePresentation] {
        let assigned = Set(model.snapshot.folders.flatMap(\.profileIDs))
        return visibleProfiles.filter { !assigned.contains($0.id) }
    }

    private func profiles(in folder: FolderPresentation) -> [ProfilePresentation] {
        let profileIDs = Set(folder.profileIDs)
        return visibleProfiles.filter { profileIDs.contains($0.id) }
    }

    private func beginFolderEditor(_ folder: FolderPresentation) {
        folderEditorID = folder.id
        folderName = folder.name
        isFolderEditorPresented = true
    }
}

private struct FolderEditorSheet: View {
    let title: String
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            TextField(AppText.string("Folder name", korean: "폴더 이름"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppText.string("Folder name", korean: "폴더 이름"))
            HStack {
                Spacer()
                Button(AppText.cancel, action: onCancel)
                Button(AppText.save, action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct ProfileSidebarRow: View {
    let profile: ProfilePresentation
    let showsTags: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .lineLimit(1)
                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(AppText.string("Favorite", korean: "즐겨찾기"))
                    }
                }
                Text(profile.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showsTags, !profile.tags.isEmpty {
                    Text(profile.tags.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var statusSymbol: String {
        profile.activeSessionState?.symbolName ?? "server.rack"
    }

    private var statusColor: Color {
        guard let state = profile.activeSessionState else { return .accentColor }
        switch state {
        case .connected: return .green
        case .failed: return .red
        case .connecting, .authenticating, .reconnecting: return .orange
        case .idle, .disconnected: return .secondary
        }
    }

    private var accessibilityDescription: String {
        let connection = profile.isActive
            ? AppText.string("active connection", korean: "활성 연결")
            : AppText.string("not connected", korean: "연결되지 않음")
        return "\(profile.name), \(profile.endpoint), \(connection)"
    }
}
