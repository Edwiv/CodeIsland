import AppKit
import XCTest
@testable import CodeIsland

@MainActor
final class PanelWindowControllerTests: XCTestCase {
    func testCollapsedPanelUsesCompactContentSizeWithGlowAllowance() {
        let size = PanelWindowController.collapsedPanelSize(
            contentSize: NSSize(width: 310.2, height: 37.1),
            maximumSize: NSSize(width: 620, height: 600)
        )

        XCTAssertEqual(size.width, 359)
        XCTAssertEqual(size.height, 62)
    }

    func testCollapsedPanelSizeNeverExceedsExpandedPanel() {
        let size = PanelWindowController.collapsedPanelSize(
            contentSize: NSSize(width: 700, height: 800),
            maximumSize: NSSize(width: 620, height: 600)
        )

        XCTAssertEqual(size, NSSize(width: 620, height: 600))
    }

    func testExpandedEnvelopeKeepsMaximumWindowDuringContentAnimation() {
        let size = PanelWindowController.panelFrameSize(
            usesExpandedEnvelope: true,
            collapsedContentSize: NSSize(width: 310, height: 38),
            maximumSize: NSSize(width: 620, height: 600)
        )

        XCTAssertEqual(size, NSSize(width: 620, height: 600))
    }

    func testCollapsedEnvelopeUsesCompactWindowAfterAnimationSettles() {
        let size = PanelWindowController.panelFrameSize(
            usesExpandedEnvelope: false,
            collapsedContentSize: NSSize(width: 310, height: 38),
            maximumSize: NSSize(width: 620, height: 600)
        )

        XCTAssertEqual(size, NSSize(width: 358, height: 62))
    }

    func testSurfaceWillChangeRunsBeforeObservedSurfaceMutation() {
        let appState = AppState()
        var observedOldSurface: IslandSurface?
        var observedCurrentSurface: IslandSurface?
        var observedNewSurface: IslandSurface?
        appState.surfaceWillChange = { oldSurface, newSurface in
            observedOldSurface = oldSurface
            observedCurrentSurface = appState.surface
            observedNewSurface = newSurface
        }

        appState.surface = .sessionList

        XCTAssertEqual(observedOldSurface, .collapsed)
        XCTAssertEqual(observedCurrentSurface, .collapsed)
        XCTAssertEqual(observedNewSurface, .sessionList)
        XCTAssertEqual(appState.surface, .sessionList)
    }

    func testScreenHopMotionUsesMoreVisibleTiming() {
        let motion = PanelWindowController.screenHopMotion()

        XCTAssertEqual(motion.outgoingOffset, 18)
        XCTAssertEqual(motion.incomingOffset, 30)
        XCTAssertEqual(motion.fadeOutDuration, 0.14, accuracy: 0.001)
        XCTAssertEqual(motion.incomingPauseDuration, 0.06, accuracy: 0.001)
        XCTAssertEqual(motion.fadeInDuration, 0.34, accuracy: 0.001)
    }

    func testScreenHopFramesRetractOldFrameAndDropIntoNewFrame() {
        let oldFrame = NSRect(x: 100, y: 820, width: 420, height: 180)
        let newFrame = NSRect(x: 1800, y: 900, width: 420, height: 180)

        let frames = PanelWindowController.screenHopFrames(
            oldFrame: oldFrame,
            newFrame: newFrame
        )

        XCTAssertEqual(frames.outgoing.origin.x, oldFrame.origin.x)
        XCTAssertEqual(frames.outgoing.origin.y, oldFrame.origin.y + 18)
        XCTAssertEqual(frames.outgoing.size, oldFrame.size)

        XCTAssertEqual(frames.incoming.origin.x, newFrame.origin.x)
        XCTAssertEqual(frames.incoming.origin.y, newFrame.origin.y + 30)
        XCTAssertEqual(frames.incoming.size, newFrame.size)
    }
}
