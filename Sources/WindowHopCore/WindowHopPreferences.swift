import Foundation

/// Saved presentation and list choices. Keyboard capture has a separate model.
public struct WindowHopPreferences: Codable, Equatable {
    public enum SidebarEdge: String, Codable, CaseIterable { case left, right }

    public var showsOnAllDisplays = true
    public var primaryList = WindowListPolicy()
    public var alternateList = WindowListPolicy()
    public var sidebarList = WindowListPolicy()
    public var sidebarEnabled = false
    public var sidebarEdge: SidebarEdge = .right
    public var sidebarCurrentDisplayOnly = true
    public var sidebarAutoHide = true
    public var showsBadges = true
    public var gestureEnabled = false
    public var ignoredBundleIdentifiers: [String] = []

    public static let defaults = WindowHopPreferences()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showsOnAllDisplays, primaryList, alternateList, sidebarList
        case sidebarEnabled, sidebarEdge, sidebarCurrentDisplayOnly, sidebarAutoHide
        case showsBadges, gestureEnabled, ignoredBundleIdentifiers
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsOnAllDisplays = try values.decodeIfPresent(Bool.self, forKey: .showsOnAllDisplays) ?? true
        primaryList = try values.decodeIfPresent(WindowListPolicy.self, forKey: .primaryList) ?? WindowListPolicy()
        alternateList = try values.decodeIfPresent(WindowListPolicy.self, forKey: .alternateList) ?? WindowListPolicy()
        sidebarList = try values.decodeIfPresent(WindowListPolicy.self, forKey: .sidebarList) ?? WindowListPolicy()
        sidebarEnabled = try values.decodeIfPresent(Bool.self, forKey: .sidebarEnabled) ?? false
        sidebarEdge = try values.decodeIfPresent(SidebarEdge.self, forKey: .sidebarEdge) ?? .right
        sidebarCurrentDisplayOnly = try values.decodeIfPresent(Bool.self, forKey: .sidebarCurrentDisplayOnly) ?? true
        sidebarAutoHide = try values.decodeIfPresent(Bool.self, forKey: .sidebarAutoHide) ?? true
        showsBadges = try values.decodeIfPresent(Bool.self, forKey: .showsBadges) ?? true
        gestureEnabled = try values.decodeIfPresent(Bool.self, forKey: .gestureEnabled) ?? false
        ignoredBundleIdentifiers = try values.decodeIfPresent([String].self, forKey: .ignoredBundleIdentifiers) ?? []
    }
}
