import Foundation

enum AppText {
    static var usesKorean: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("ko") == true
    }

    static func string(_ english: String, korean: String) -> String {
        usesKorean ? korean : english
    }

    static func plural(
        _ englishSingular: String,
        englishPlural: String,
        korean: String,
        count: Int
    ) -> String {
        if usesKorean { return korean }
        return count == 1 ? englishSingular : englishPlural
    }

    static let appName = "osXterm"
    static let newConnection = string("New Connection", korean: "새 연결")
    static let localTerminal = string("Local Terminal", korean: "로컬 터미널")
    static let connect = string("Connect", korean: "연결")
    static let disconnect = string("Disconnect", korean: "연결 해제")
    static let reconnect = string("Reconnect", korean: "재연결")
    static let cancel = string("Cancel", korean: "취소")
    static let save = string("Save", korean: "저장")
    static let delete = string("Delete", korean: "삭제")
    static let duplicate = string("Duplicate", korean: "복제")
    static let edit = string("Edit", korean: "편집")
    static let settings = string("Settings", korean: "설정")
    static let profiles = string("Profiles", korean: "프로필")
    static let favorites = string("Favorites", korean: "즐겨찾기")
    static let recent = string("Recent", korean: "최근 연결")
    static let folders = string("Folders", korean: "폴더")
    static let transfers = string("Transfers", korean: "전송")
    static let tunnels = string("Tunnels", korean: "터널")
    static let connection = string("Connection", korean: "연결")
    static let unavailable = string("Core service is not configured.", korean: "코어 서비스가 아직 구성되지 않았습니다.")
}
