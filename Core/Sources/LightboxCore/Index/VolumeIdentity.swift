import Foundation

/// Which volume a path is on, by both of the ids macOS offers, because neither
/// is sufficient alone.
///
/// `uuid` is the stable one: `URLResourceValues.volumeUUIDString` is a property
/// of the filesystem, assigned when it is created and carried across unmounts,
/// reboots and replugs. It is what a row in the index stores as its volume
/// identity.
///
/// `device` is `st_dev`, which is assigned at *mount* time. It is unique among
/// the volumes mounted right now and it is renumbered the next time the drive
/// comes back, which is exactly why it cannot be an identity — an external
/// drive replugged after a reboot gets a different one, and every row already
/// in the index would then look as though it came from another filesystem. It
/// is still carried here for two reasons: an inode is unique only within a
/// volume, and rows written before schema v2 have no UUID to compare.
///
/// Not every filesystem publishes a UUID. SMB shares and some FAT volumes
/// return nil, so `uuid` is optional and falling back to `st_dev` is a
/// documented path rather than an error — on such a volume the index is exactly
/// as good, and exactly as fragile across a replug, as it was before schema v2.
public struct VolumeIdentity: Sendable, Hashable {
    public let device: Int64
    public let uuid: String?

    public init(device: Int64, uuid: String?) {
        self.device = device
        self.uuid = uuid
    }

    /// The volume currently answering at `url`, or nil if it is gone or is no
    /// longer a directory.
    ///
    /// `stat` first: a URL resource value on a path that does not resolve is a
    /// less specific failure than "there is nothing mounted here", and the
    /// directory check is what makes a stale mount point distinguishable from a
    /// live one.
    public init?(ofDirectory url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        self.device = Int64(st.st_dev)
        self.uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Whether `current` is the volume this identity describes.
    ///
    /// The UUID decides whenever this identity has one: it survives the unmount
    /// that renumbers `st_dev`, so a replugged drive matches, and a *different*
    /// filesystem that happens to have been handed the old `st_dev` does not.
    /// A volume that has since stopped reporting a UUID does not match either —
    /// that is not the volume this identity was taken from, and the safe answer
    /// to "am I sure?" is no.
    ///
    /// Only an identity captured from a volume that published no UUID falls
    /// back to comparing `st_dev`, which is all such a volume has — and it
    /// falls back whether or not the volume now reports one, exactly as the
    /// reconcile's matching rule matches a NULL `volume_uuid` row by `device`
    /// even when the root has a UUID. The two must not disagree, and `st_dev`
    /// is unique among the volumes mounted right now, so a matching one is
    /// this volume with a resource-value read that failed the first time.
    public func matches(_ current: VolumeIdentity) -> Bool {
        if let uuid { return current.uuid == uuid }
        return current.device == device
    }
}
