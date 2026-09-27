import Foundation

/// Filtering only consumes cached metadata. Input order is the index's MRU order.
public struct WindowListPolicy: Codable, Equatable {
    public enum SpaceScope: String, Codable, CaseIterable {
        case all, visibleAndFullScreen, visible
    }

    public enum InactivePlacement: String, Codable, CaseIterable {
        case normal, bottom, exclude
    }

    public var spaceScope: SpaceScope
    public var minimized: InactivePlacement
    public var hidden: InactivePlacement
    public var currentApplicationOnly: Bool
    public var includeApplicationsWithoutWindows: Bool

    public init(spaceScope: SpaceScope = .all,
                minimized: InactivePlacement = .normal,
                hidden: InactivePlacement = .normal,
                currentApplicationOnly: Bool = false,
                includeApplicationsWithoutWindows: Bool = true) {
        self.spaceScope = spaceScope
        self.minimized = minimized
        self.hidden = hidden
        self.currentApplicationOnly = currentApplicationOnly
        self.includeApplicationsWithoutWindows = includeApplicationsWithoutWindows
    }

    public func apply(to windows: [WindowItem], frontmostProcessIdentifier: Int32? = nil,
                      displayID: UInt32? = nil) -> [WindowItem] {
        var normal: [WindowItem] = []
        var deferred: [WindowItem] = []
        normal.reserveCapacity(windows.count)
        for window in windows {
            if currentApplicationOnly {
                guard let frontmostProcessIdentifier, window.processIdentifier == frontmostProcessIdentifier else { continue }
            }
            if window.isApplicationOnly && !includeApplicationsWithoutWindows { continue }
            if window.isMinimized && minimized == .exclude { continue }
            if window.isHidden && hidden == .exclude { continue }
            // Windowless apps have no physical display/Space. Keep them available
            // on every display; unknown window metadata has the same safe fallback.
            if let displayID, let actualDisplay = window.displayID, actualDisplay != displayID { continue }
            if !window.isApplicationOnly, window.isOnVisibleSpace == false {
                switch spaceScope {
                case .all: break
                case .visibleAndFullScreen: if !window.isFullScreen { continue }
                case .visible: continue
                }
            }
            if (window.isMinimized && minimized == .bottom) || (window.isHidden && hidden == .bottom) {
                deferred.append(window)
            } else {
                normal.append(window)
            }
        }
        normal.append(contentsOf: deferred)
        return normal
    }
}
