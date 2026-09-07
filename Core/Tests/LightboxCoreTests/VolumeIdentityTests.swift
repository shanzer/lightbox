import Testing
import Foundation
@testable import LightboxCore

struct VolumeIdentityTests {
    /// The rule the whole change rests on: `st_dev` is a mount id and the UUID
    /// is the filesystem's, so a replug that renumbers the former must still
    /// match and a different filesystem handed the old number must not.
    @Test func theUUIDDecidesWheneverTheCapturedIdentityHasOne() {
        let seagate = VolumeIdentity(device: 16, uuid: "VOL-A")

        // Replugged: same filesystem, fresh mount id.
        #expect(seagate.matches(VolumeIdentity(device: 42, uuid: "VOL-A")))
        // A different drive that inherited the old mount id.
        #expect(!seagate.matches(VolumeIdentity(device: 16, uuid: "VOL-B")))
    }

    /// A volume that has stopped reporting a UUID is not evidence that it is
    /// the same one. The safe answer to "am I sure?" is no.
    @Test func aVolumeThatNoLongerPublishesAUUIDDoesNotMatch() {
        #expect(!VolumeIdentity(device: 16, uuid: "VOL-A")
            .matches(VolumeIdentity(device: 16, uuid: nil)))
    }

    /// SMB and some FAT volumes publish no UUID. There, `st_dev` is all there
    /// is, and the comparison falls back to it rather than failing.
    @Test func withoutAUUIDTheComparisonFallsBackToTheDevice() {
        let share = VolumeIdentity(device: 16, uuid: nil)
        #expect(share.matches(VolumeIdentity(device: 16, uuid: nil)))
        #expect(!share.matches(VolumeIdentity(device: 42, uuid: nil)))
        // A UUID appearing where there was none is the *same* fallback, not a
        // mismatch: `st_dev` is unique among the volumes mounted right now, so
        // a matching one is this volume with a resource-value read that failed
        // the first time. It is also the rule the reconcile already uses — a
        // row with no `volume_uuid` is matched by `device` even when the root
        // has one — and the two must not disagree.
        #expect(share.matches(VolumeIdentity(device: 16, uuid: "VOL-A")))
    }

    @Test func readingADirectoryYieldsItsDeviceAndSurvivesItsAbsence() throws {
        let tree = try TempTree()
        let identity = try #require(VolumeIdentity(ofDirectory: tree.root))

        var st = stat()
        #expect(stat(tree.root.path, &st) == 0)
        #expect(identity.device == Int64(st.st_dev))
        // Whether a UUID is published is a property of the filesystem, so it is
        // not asserted; that it agrees with the resource value is.
        let published = (try? tree.root.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString
        #expect(identity.uuid == published)

        #expect(VolumeIdentity(ofDirectory: tree.root.appendingPathComponent("nope")) == nil)
        // A file is not a volume root's stand-in: the guard is about something
        // being mounted here, and only a directory can answer that.
        let file = try tree.file("a.jpg")
        #expect(VolumeIdentity(ofDirectory: file) == nil)
    }
}
