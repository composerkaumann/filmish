import Foundation
import XCTest
@testable import Filmish

final class ImageProbeTests: XCTestCase {
    func testAttachedPNGDimensions() throws {
        guard let path = ProcessInfo.processInfo.environment["PNG_TEST_DIR"] else {
            throw XCTSkip("PNG_TEST_DIR was not provided")
        }

        let images = AppModel.scanFolder(URL(fileURLWithPath: path))
        XCTAssertEqual(images.count, 5)
        XCTAssertTrue(images.allSatisfy(\.isReadable))
        XCTAssertTrue(images.allSatisfy { $0.width == 1080 && $0.height == 1920 })
        XCTAssertTrue(images.allSatisfy { $0.dimensions == "1080×1920" })
    }

    func testRescanPreservesExistingOrderAndAppendsNewImagesAlphabetically() {
        let folder = URL(fileURLWithPath: "/tmp/order-test")
        let a = image(named: "a.png", in: folder)
        let b = image(named: "b.png", in: folder)
        let c = image(named: "c.png", in: folder)
        let d = image(named: "d.png", in: folder)

        let result = AppModel.mergeScannedImages([d, a, c, b], preserving: [c, a, b])
        XCTAssertEqual(result.map(\.name), ["c.png", "a.png", "b.png", "d.png"])
    }

    func testRescanPreservesIndividualFadeSettings() {
        let folder = URL(fileURLWithPath: "/tmp/order-test")
        var configured = image(named: "a.png", in: folder)
        configured.transitionName = "dissolve"
        configured.transitionDurationSeconds = 1.24
        configured.fixedDisplaySecondsText = "2.5"

        let result = AppModel.mergeScannedImages(
            [image(named: "a.png", in: folder)],
            preserving: [configured]
        )

        XCTAssertEqual(result[0].id, configured.id)
        XCTAssertEqual(result[0].transitionName, "dissolve")
        XCTAssertEqual(result[0].transitionDurationSeconds, 1.24)
        XCTAssertEqual(result[0].fixedDisplaySecondsText, "2.5")
    }

    func testAlphabeticalResetUsesNaturalFileNameOrder() {
        let folder = URL(fileURLWithPath: "/tmp/order-test")
        let images = [image(named: "10.png", in: folder), image(named: "2.png", in: folder), image(named: "1.png", in: folder)]
        XCTAssertEqual(AppModel.alphabeticallySorted(images).map(\.name), ["1.png", "2.png", "10.png"])
    }

    func testMovingAnImageUpdatesPlaybackOrder() {
        let folder = URL(fileURLWithPath: "/tmp/order-test")
        var images = [image(named: "a.png", in: folder), image(named: "b.png", in: folder), image(named: "c.png", in: folder)]

        AppModel.moveImage(&images, id: images[0].id, onto: images[2].id)

        XCTAssertEqual(images.map(\.name), ["b.png", "c.png", "a.png"])
    }

    func testLinkedFadeChangeUpdatesEveryImage() async {
        await MainActor.run {
            let folder = URL(fileURLWithPath: "/tmp/order-test")
            let model = AppModel()
            model.images = [
                image(named: "a.png", in: folder),
                image(named: "b.png", in: folder),
                image(named: "c.png", in: folder),
            ]

            model.setTransitionName("dissolve", for: model.images[1].id)
            model.setTransitionDuration(1.3, for: model.images[1].id)

            XCTAssertTrue(model.images.allSatisfy { $0.transitionName == "dissolve" })
            XCTAssertTrue(model.images.allSatisfy { $0.transitionDurationSeconds == 1.3 })
        }
    }

    func testUnlinkedFadeChangeUpdatesOnlyOneImage() async {
        await MainActor.run {
            let folder = URL(fileURLWithPath: "/tmp/order-test")
            let model = AppModel()
            model.images = [
                image(named: "a.png", in: folder),
                image(named: "b.png", in: folder),
                image(named: "c.png", in: folder),
            ]
            model.setSameFadesEnabled(false)

            model.setTransitionName("wipeleft", for: model.images[1].id)
            model.setTransitionDuration(0.2, for: model.images[1].id)

            XCTAssertEqual(model.images.map(\.transitionName), ["none", "wipeleft", "none"])
            XCTAssertEqual(model.images.map(\.transitionDurationSeconds), [1.0, 0.2, 1.0])
        }
    }

    func testFixedDisplayTimeNeverPropagatesWithLinkedFades() async {
        await MainActor.run {
            let folder = URL(fileURLWithPath: "/tmp/order-test")
            let model = AppModel()
            model.images = [
                image(named: "a.png", in: folder),
                image(named: "b.png", in: folder),
                image(named: "c.png", in: folder),
            ]

            model.setFixedDisplaySecondsText("2.5", for: model.images[1].id)

            XCTAssertEqual(model.images.map(\.fixedDisplaySecondsText), ["", "2.5", ""])
        }
    }

    func testRemovingImageOnlyChangesSlideshowList() async {
        await MainActor.run {
            let folder = URL(fileURLWithPath: "/tmp/order-test")
            let model = AppModel()
            model.images = [
                image(named: "correct.png", in: folder),
                image(named: "wrong-size.png", in: folder),
                image(named: "also-correct.png", in: folder),
            ]
            let removedID = model.images[1].id

            model.removeImage(removedID)

            XCTAssertEqual(model.images.map(\.name), ["correct.png", "also-correct.png"])
            XCTAssertFalse(model.images.contains { $0.id == removedID })
        }
    }

    func testDecimalSecondsRoundToNearestFrame() {
        XCTAssertEqual(AppModel.roundedFrames(seconds: 1.2, fps: 24), 29)
        XCTAssertEqual(AppModel.roundedFrames(seconds: 1.2, fps: 25), 30)
        XCTAssertEqual(AppModel.roundedFrames(seconds: 1.2, fps: 30), 36)
    }

    func testFixedAndAutomaticDisplayAllocation() throws {
        let result = AppModel.allocateHoldFrames(
            totalFrames: 300,
            transitionFrames: 30,
            fixedDisplaySeconds: [2.0, nil, nil],
            fps: 30
        )
        XCTAssertEqual(try result.get(), [60, 105, 105])
    }

    func testEdgeFadesReduceAutomaticClearDisplayTime() throws {
        let result = AppModel.allocateHoldFrames(
            totalFrames: 300,
            transitionFrames: 30 + 12 + 18,
            fixedDisplaySeconds: [2.0, nil, nil],
            fps: 30
        )
        XCTAssertEqual(try result.get(), [60, 90, 90])
    }

    func testAutomaticDisplayAllocationMayDifferByOneFrame() throws {
        let result = AppModel.allocateHoldFrames(
            totalFrames: 101,
            transitionFrames: 20,
            fixedDisplaySeconds: [nil, nil, nil],
            fps: 30
        )
        XCTAssertEqual(try result.get(), [27, 27, 27])
    }

    func testAllFixedDisplayTimesMustExactlyFillClearBudget() {
        let result = AppModel.allocateHoldFrames(
            totalFrames: 300,
            transitionFrames: 30,
            fixedDisplaySeconds: [2.0, 3.0, 3.0],
            fps: 30
        )
        XCTAssertEqual(result, .failure(.allFixedTimesDoNotMatch))
    }

    func testFixedDisplayTimesCannotConsumeAutomaticRows() {
        let result = AppModel.allocateHoldFrames(
            totalFrames: 100,
            transitionFrames: 20,
            fixedDisplaySeconds: [2.65, nil],
            fps: 30
        )
        XCTAssertEqual(result, .failure(.automaticTimesTooShort))
    }

    private func image(named name: String, in folder: URL) -> ImageInfo {
        ImageInfo(
            name: name,
            url: folder.appendingPathComponent(name),
            dimensions: "100×100",
            width: 100,
            height: 100,
            probeError: nil
        )
    }
}
