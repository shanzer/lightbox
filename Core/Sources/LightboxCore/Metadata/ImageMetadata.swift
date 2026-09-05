import Foundation

public struct ImageMetadata: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var captureTime: Date?
    /// The EXIF `OffsetTimeOriginal` string, e.g. `-05:00`, when present.
    /// `DateTimeOriginal` carries no zone, so without this the capture time is
    /// only meaningful relative to an assumed zone.
    public var captureOffset: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var orientation: Int

    public init(width: Int, height: Int, captureTime: Date? = nil, captureOffset: String? = nil,
                cameraMake: String? = nil, cameraModel: String? = nil, orientation: Int = 1) {
        self.width = width; self.height = height
        self.captureTime = captureTime; self.captureOffset = captureOffset
        self.cameraMake = cameraMake; self.cameraModel = cameraModel
        self.orientation = orientation
    }
}

public enum MetadataError: Error, Equatable {
    case unreadable
    case notAnImage
}

public protocol MetadataReading: Sendable {
    func read(_ url: URL) throws -> ImageMetadata
}
