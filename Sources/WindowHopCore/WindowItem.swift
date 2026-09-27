import Foundation

/// The displayable, immutable portion of a window. The platform layer owns its AX handle.
public struct WindowItem: Codable, Equatable, Identifiable {
    public let id: String
    public let appName: String
    public let title: String
    public let bundleIdentifier: String
    public let isMinimized: Bool
    public let isHidden: Bool

    public init(
        id: String,
        appName: String,
        title: String,
        bundleIdentifier: String,
        isMinimized: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.appName = appName
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.isMinimized = isMinimized
        self.isHidden = isHidden
    }
}
