import CoreGraphics
import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct DesktopCoverageGeometryTests {
    @Test
    func quartzConversionFlipsTheVerticalAxisWithoutChangingSizeOrHorizontalPosition() {
        let appKit = CGRect(x: 120, y: 200, width: 640, height: 480)
        let converted = DesktopCoverageGeometry.quartzRect(from: appKit, desktopTop: 1_080)

        #expect(converted == CGRect(x: 120, y: 400, width: 640, height: 480))
    }

    @Test
    func quartzConversionSupportsScreensLeftAboveAndBelowThePrimaryDisplay() {
        let left = CGRect(x: -1_600, y: -200, width: 1_600, height: 900)
        let above = CGRect(x: -200, y: 900, width: 1_024, height: 768)
        let below = CGRect(x: 200, y: -720, width: 1_280, height: 720)

        #expect(DesktopCoverageGeometry.quartzRect(from: left, desktopTop: 900)
                == CGRect(x: -1_600, y: 200, width: 1_600, height: 900))
        #expect(DesktopCoverageGeometry.quartzRect(from: above, desktopTop: 900)
                == CGRect(x: -200, y: -768, width: 1_024, height: 768))
        #expect(DesktopCoverageGeometry.quartzRect(from: below, desktopTop: 900)
                == CGRect(x: 200, y: 900, width: 1_280, height: 720))
    }

    @Test
    func anExactOrLargerWindowCoversTheTarget() {
        let target = CGRect(x: 30, y: 40, width: 100, height: 80)

        #expect(DesktopCoverageGeometry.isCovered(target, by: [target]))
        #expect(DesktopCoverageGeometry.isCovered(target,
                                                  by: [CGRect(x: -50, y: -50, width: 300, height: 300)]))
    }

    @Test
    func aPartiallyVisibleDesktopIsNotCovered() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let partial = CGRect(x: 0, y: 0, width: 60, height: 100)

        #expect(!DesktopCoverageGeometry.isCovered(target, by: [partial]))
        #expect(!DesktopCoverageGeometry.isCovered(target, by: []))
    }

    @Test
    func overlappingWindowsCanTogetherCoverTheWholeDesktop() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = CGRect(x: -10, y: -10, width: 75, height: 120)
        let right = CGRect(x: 40, y: -10, width: 70, height: 120)

        #expect(!DesktopCoverageGeometry.isCovered(target, by: [left]))
        #expect(!DesktopCoverageGeometry.isCovered(target, by: [right]))
        #expect(DesktopCoverageGeometry.isCovered(target, by: [left, right]))
        #expect(DesktopCoverageGeometry.isCovered(target, by: [right, left]))
    }

    @Test
    func aNarrowRealGapMustKeepTheDesktopVisible() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = CGRect(x: 0, y: 0, width: 49.875, height: 100)
        let right = CGRect(x: 50.125, y: 0, width: 49.875, height: 100)

        #expect(!DesktopCoverageGeometry.isCovered(target, by: [left, right]),
                "Even a quarter-point uncovered strip is a real gap in the supplied target.")
    }

    @Test
    func boundingBoxesDoNotFillTheHoleBetweenDisjointWindows() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let corners = [CGRect(x: 0, y: 0, width: 40, height: 40),
                       CGRect(x: 60, y: 60, width: 40, height: 40)]

        #expect(!DesktopCoverageGeometry.isCovered(target, by: corners),
                "The windows' outer bounding rectangle is not their covered area.")
    }

    @Test
    func overlappingAreaIsNotCountedTwice() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = CGRect(x: 0, y: 0, width: 60, height: 100)
        let right = CGRect(x: 50, y: 0, width: 50, height: 100)

        #expect(!DesktopCoverageGeometry.isCovered(target, by: [left, left, left]),
                "Repeated windows cover only the same left-hand region.")
        #expect(DesktopCoverageGeometry.isCovered(target, by: [left, left, right, right]))
    }

    @Test
    func windowsOutsideTheTargetDoNotContributeCoverage() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let outside = [CGRect(x: -200, y: 0, width: 100, height: 100),
                       CGRect(x: 100, y: 0, width: 100, height: 100),
                       CGRect(x: 0, y: 100, width: 100, height: 100)]

        #expect(!DesktopCoverageGeometry.isCovered(target, by: outside))
        #expect(DesktopCoverageGeometry.isCovered(target, by: outside + [target]))
    }

    @Test
    func adjacentFractionalRectanglesCoverWithoutRoundingTheirEdges() {
        let target = CGRect(x: 0.125, y: 0.25, width: 100.5, height: 80.75)
        let left = CGRect(x: 0.125, y: 0.25, width: 50.25, height: 80.75)
        let right = CGRect(x: 50.375, y: 0.25, width: 50.25, height: 80.75)

        #expect(DesktopCoverageGeometry.isCovered(target, by: [left, right]))
    }

    @Test
    func coverageWorksEntirelyInNegativeDesktopCoordinates() {
        let target = CGRect(x: -1_920, y: -1_080, width: 1_920, height: 1_080)
        let upper = CGRect(x: -1_920, y: -1_080, width: 1_920, height: 600)
        let lower = CGRect(x: -1_920, y: -540, width: 1_920, height: 540)

        #expect(DesktopCoverageGeometry.isCovered(target, by: [upper, lower]))
        #expect(!DesktopCoverageGeometry.isCovered(target, by: [upper]))
    }

    @Test
    func invalidOrEmptyTargetsFailOpen() {
        let invalidTargets: [CGRect] = [
            .zero, .null, .infinite,
            CGRect(x: 0, y: 0, width: -20, height: 20),
            CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20)
        ]
        let covering = CGRect(x: -1_000, y: -1_000, width: 2_000, height: 2_000)

        for target in invalidTargets {
            #expect(!DesktopCoverageGeometry.isCovered(target, by: [covering]),
                    "Invalid target geometry must not pause a wallpaper.")
        }
    }

    @Test
    func invalidCoverGeometryCannotHideTheDesktop() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let invalidCovers: [CGRect] = [
            .zero, .null, .infinite,
            CGRect(x: 100, y: 0, width: -100, height: 100),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)
        ]

        #expect(!DesktopCoverageGeometry.isCovered(target, by: invalidCovers))
        #expect(DesktopCoverageGeometry.isCovered(target, by: invalidCovers + [target]),
                "A bad record does not prevent a separate valid window from covering the target.")
    }

    @Test
    func aVisibleOpaqueNormalWindowRetainsItsActualBounds() {
        let bounds = CGRect(x: -1_280.5, y: 40.25, width: 900.5, height: 700.75)

        #expect(DesktopCoveringWindow(info: windowInfo(bounds: bounds))?.bounds == bounds)
    }

    @Test
    func hiddenOrSystemLevelWindowsAreNotTreatedAsDesktopCovers() {
        var hidden = windowInfo()
        hidden[kCGWindowIsOnscreen as String] = false
        #expect(DesktopCoveringWindow(info: hidden) == nil)

        for level in [-2_147_483_625, -1, 1, 2, 4, 25] {
            var info = windowInfo()
            info[kCGWindowLayer as String] = level
            #expect(DesktopCoveringWindow(info: info) == nil,
                    "Desktop, tracker, menu-bar and other unrecognized levels must not become app covers.")
        }
    }

    @Test
    func floatingApplicationWindowsCanAlsoCoverTheDesktop() {
        let bounds = CGRect(x: 50, y: 60, width: 800, height: 600)
        var info = windowInfo(bounds: bounds)
        info[kCGWindowLayer as String] = 3

        #expect(DesktopCoveringWindow(info: info)?.bounds == bounds,
                "Always-on-top app windows at the standard floating level still hide wallpaper.")
    }

    @Test
    func transparentOrInvalidAlphaRecordsDoNotHideTheDesktop() {
        for alpha in [0.0, 0.5, 0.98, Double.nan, Double.infinity] {
            var info = windowInfo()
            info[kCGWindowAlpha as String] = alpha
            #expect(DesktopCoveringWindow(info: info) == nil)
        }
        for alpha in [0.99, 1.0] {
            var info = windowInfo()
            info[kCGWindowAlpha as String] = alpha
            #expect(DesktopCoveringWindow(info: info) != nil)
        }
    }

    @Test
    func missingOrMalformedSnapshotMetadataFailsOpen() {
        for key in [kCGWindowBounds, kCGWindowLayer, kCGWindowAlpha, kCGWindowIsOnscreen] {
            var info = windowInfo()
            info.removeValue(forKey: key as String)
            #expect(DesktopCoveringWindow(info: info) == nil,
                    "An incomplete snapshot cannot establish that a window covers the desktop.")
        }

        let malformedBounds: [Any] = [
            "not a rectangle",
            ["Width": 100, "Height": 100],
            ["X": 0, "Y": 0, "Width": -100, "Height": 100],
            ["X": 0, "Y": 0, "Width": 0, "Height": 100],
            ["X": Double.nan, "Y": 0, "Width": 100, "Height": 100],
            ["X": 0, "Y": 0, "Width": Double.infinity, "Height": 100]
        ]
        for bounds in malformedBounds {
            var info = windowInfo()
            info[kCGWindowBounds as String] = bounds
            #expect(DesktopCoveringWindow(info: info) == nil)
        }
    }

    private func windowInfo(bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> [String: Any] {
        [kCGWindowBounds as String: ["X": bounds.origin.x, "Y": bounds.origin.y,
                                    "Width": bounds.width, "Height": bounds.height],
         kCGWindowLayer as String: 0,
         kCGWindowAlpha as String: 1.0,
         kCGWindowIsOnscreen as String: true]
    }
}
