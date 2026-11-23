import XCTest
@testable import FileLens

final class DriveTests: XCTestCase {
    func testExternalDetectionExcludesInternalAndNetworkVolumes() {
        XCTAssertTrue(DriveDiscovery.isExternal(local: true, internalVolume: false, removable: false, ejectable: false))
        XCTAssertTrue(DriveDiscovery.isExternal(local: true, internalVolume: nil, removable: true, ejectable: true))
        XCTAssertFalse(DriveDiscovery.isExternal(local: true, internalVolume: true, removable: false, ejectable: false))
        XCTAssertFalse(DriveDiscovery.isExternal(local: false, internalVolume: false, removable: false, ejectable: false))
        XCTAssertFalse(DriveDiscovery.isExternal(local: nil, internalVolume: nil, removable: nil, ejectable: nil))
    }

    func testSelectionUsesMostSpecificVolumeAndPathBoundary() {
        let startup = MountedDrive(url: URL(fileURLWithPath: "/"), name: "Startup", external: false)
        let external = MountedDrive(url: URL(fileURLWithPath: "/Volumes/Archive"), name: "Archive", external: true)
        let drives = [startup, external]
        XCTAssertEqual(DriveDiscovery.containing(URL(fileURLWithPath: "/Volumes/Archive/photos"), in: drives), external)
        XCTAssertEqual(DriveDiscovery.containing(external.url, in: drives), external)
        XCTAssertEqual(DriveDiscovery.containing(URL(fileURLWithPath: "/Volumes/Archive-copy"), in: drives), startup)
        XCTAssertEqual(DriveDiscovery.containing(URL(fileURLWithPath: "/Users"), in: drives), startup)
        XCTAssertNil(DriveDiscovery.containing(URL(fileURLWithPath: "/Users"), in: [external]))
    }
}
