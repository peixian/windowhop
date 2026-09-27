import Foundation

/// The displayable, immutable portion of a window. The platform layer owns its AX handle.
public struct WindowItem: Codable, Equatable, Identifiable {
    public let id: String
    public let appName: String
    public let title: String
    public let bundleIdentifier: String
    public let isMinimized: Bool
    public let isHidden: Bool
    public let processIdentifier: Int32?
    /// Nil means macOS did not expose enough metadata to classify this window.
    public let isOnVisibleSpace: Bool?
    public let isFullScreen: Bool
    public let displayID: UInt32?
    public let spaceIDs: [UInt64]
    public let spaceTitle: String?
    public let isApplicationOnly: Bool
    public let badge: String?

    public init(
        id: String,
        appName: String,
        title: String,
        bundleIdentifier: String,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        processIdentifier: Int32? = nil,
        isOnVisibleSpace: Bool? = nil,
        isFullScreen: Bool = false,
        displayID: UInt32? = nil,
        spaceIDs: [UInt64] = [],
        spaceTitle: String? = nil,
        isApplicationOnly: Bool = false,
        badge: String? = nil
    ) {
        self.id = id
        self.appName = appName
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.processIdentifier = processIdentifier
        self.isOnVisibleSpace = isOnVisibleSpace
        self.isFullScreen = isFullScreen
        self.displayID = displayID
        self.spaceIDs = spaceIDs
        self.spaceTitle = spaceTitle
        self.isApplicationOnly = isApplicationOnly
        self.badge = badge
    }

    private enum CodingKeys: String, CodingKey {
        case id, appName, title, bundleIdentifier, isMinimized, isHidden
        case processIdentifier, isOnVisibleSpace, isFullScreen, displayID, spaceIDs, spaceTitle, isApplicationOnly, badge
    }

    /// Older saved fixtures remain readable when optional discovery metadata is added.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  appName: try values.decode(String.self, forKey: .appName),
                  title: try values.decode(String.self, forKey: .title),
                  bundleIdentifier: try values.decode(String.self, forKey: .bundleIdentifier),
                  isMinimized: try values.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false,
                  isHidden: try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
                  processIdentifier: try values.decodeIfPresent(Int32.self, forKey: .processIdentifier),
                  isOnVisibleSpace: try values.decodeIfPresent(Bool.self, forKey: .isOnVisibleSpace),
                  isFullScreen: try values.decodeIfPresent(Bool.self, forKey: .isFullScreen) ?? false,
                  displayID: try values.decodeIfPresent(UInt32.self, forKey: .displayID),
                  spaceIDs: try values.decodeIfPresent([UInt64].self, forKey: .spaceIDs) ?? [],
                  spaceTitle: try values.decodeIfPresent(String.self, forKey: .spaceTitle),
                  isApplicationOnly: try values.decodeIfPresent(Bool.self, forKey: .isApplicationOnly) ?? false,
                  badge: try values.decodeIfPresent(String.self, forKey: .badge))
    }
}
