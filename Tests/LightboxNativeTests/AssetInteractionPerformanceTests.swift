import AppKit
import Testing
@testable import LightboxNative

@Test @MainActor func assetInteractionAccessibilityReusesActionsForUnchangedMetadata() throws {
    let view = AssetInteractionView()
    view.debugTargetName = "Photo.jpg"
    view.assetTags = ["Red"]
    view.compareMenuTitle = "Compare"
    view.onActivate = {}
    view.configureAccessibility(selected: false)
    let original = try #require(view.accessibilityCustomActions())
    #expect(original.count == 2)
    for _ in 0..<10 {
        view.isInteractionEnabled = true
        view.configureAccessibility(selected: false)
        let repeated = try #require(view.accessibilityCustomActions())
        #expect(repeated[0] === original[0])
        #expect(repeated[1] === original[1])
    }
    #expect(view.accessibilityLabel() == "Photo.jpg, Red")
    #expect(view.toolTip == "Photo.jpg")
    #expect(view.accessibilityRole() == .button)
    #expect(!view.isAccessibilitySelected())
    #expect(view.isAccessibilityEnabled())
    #expect(view.isAccessibilityElement())
    #expect(!view.isHidden)
}

@Test @MainActor func assetInteractionAccessibilityRefreshesOnlyChangedMetadata() throws {
    let view = AssetInteractionView()
    view.debugTargetName = "Photo.jpg"
    view.compareMenuTitle = "Compare"
    view.configureAccessibility(selected: false)
    let original = try #require(view.accessibilityCustomActions())
    #expect(view.accessibilityRole() == .image)

    view.debugTargetName = "Updated.jpg"
    view.assetTags = ["Blue", "Green"]
    view.onActivate = {}
    view.configureAccessibility(selected: true)
    #expect(view.accessibilityLabel() == "Updated.jpg, Blue, Green")
    #expect(view.toolTip == "Updated.jpg")
    #expect(view.accessibilityRole() == .button)
    #expect(view.isAccessibilitySelected())
    let afterSelection = try #require(view.accessibilityCustomActions())
    #expect(afterSelection[0] === original[0])
    #expect(afterSelection[1] === original[1])

    view.isInteractionEnabled = false
    view.configureAccessibility(selected: true)
    #expect(view.isHidden)
    #expect(!view.isAccessibilityEnabled())
    #expect(!view.isAccessibilityElement())
    let disabled = try #require(view.accessibilityCustomActions())
    #expect(disabled[0] === original[0])
    #expect(disabled[1] === original[1])

    view.menuTitles.copy = "Copy Updated"
    view.compareMenuTitle = "Compare Updated"
    view.configureAccessibility(selected: true)
    let renamed = try #require(view.accessibilityCustomActions())
    #expect(renamed[0].name == "Copy Updated")
    #expect(renamed[1].name == "Compare Updated")
    #expect(renamed[0] !== original[0])
    #expect(renamed[1] !== original[1])

    view.isInteractionEnabled = true
    view.onActivate = nil
    view.configureAccessibility(selected: false)
    #expect(!view.isHidden)
    #expect(view.isAccessibilityEnabled())
    #expect(view.isAccessibilityElement())
    #expect(!view.isAccessibilitySelected())
    #expect(view.accessibilityRole() == .image)
    let reenabled = try #require(view.accessibilityCustomActions())
    #expect(reenabled[0] === renamed[0])
    #expect(reenabled[1] === renamed[1])
}

@Test @MainActor func assetInteractionReusedAccessibilityActionsUseCurrentCallbacks() throws {
    let view = AssetInteractionView()
    view.debugTargetName = "Photo.jpg"
    view.compareMenuTitle = "Compare"
    var oldCalls = 0
    var currentCopyCalls = 0
    var currentCompareCalls = 0
    var currentActivationCalls = 0
    view.onCopy = { oldCalls += 1 }
    view.onAddToCompareTray = { oldCalls += 1 }
    view.onActivate = { oldCalls += 1 }
    view.configureAccessibility(selected: false)
    let original = try #require(view.accessibilityCustomActions())

    view.onCopy = { currentCopyCalls += 1 }
    view.onAddToCompareTray = { currentCompareCalls += 1 }
    view.onActivate = { currentActivationCalls += 1 }
    view.configureAccessibility(selected: false)
    let repeated = try #require(view.accessibilityCustomActions())
    #expect(repeated[0] === original[0])
    #expect(repeated[1] === original[1])
    #expect(repeated[0].selector == #selector(AssetInteractionView.accessibilityCopy))
    #expect(repeated[1].selector == #selector(AssetInteractionView.accessibilityCompare))
    let copyTarget = try #require(repeated[0].target as? AssetInteractionView)
    let compareTarget = try #require(repeated[1].target as? AssetInteractionView)
    #expect(copyTarget === view)
    #expect(compareTarget === view)
    #expect(copyTarget.accessibilityCopy())
    #expect(compareTarget.accessibilityCompare())
    #expect(view.accessibilityPerformPress())
    #expect(oldCalls == 0)
    #expect(currentCopyCalls == 1)
    #expect(currentCompareCalls == 1)
    #expect(currentActivationCalls == 1)

    view.isInteractionEnabled = false
    view.configureAccessibility(selected: false)
    #expect(!copyTarget.accessibilityCopy())
    #expect(!compareTarget.accessibilityCompare())
    #expect(!view.accessibilityPerformPress())
    #expect(currentCopyCalls == 1)
    #expect(currentCompareCalls == 1)
    #expect(currentActivationCalls == 1)
}
