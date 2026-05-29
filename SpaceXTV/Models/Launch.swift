import Foundation

struct NextLaunch: Equatable {
    var title: String
    var vehicle: String?
    var launchSite: String?
    var launchDate: Date
    var windowCloseDate: Date?
    var isLaunchTimePrecise: Bool
    var sourceURL: URL
    var imageURL: URL?
}
