import Testing
import Foundation
import AppKit
@testable import Todo

/// Keyboard surface: cursor movement, item moves, `dd` deletion,
/// detail opening, and event routing rules.
///
/// NOTE: AppModel holds its `navigable` weakly (views set it on appear), so
/// every test must keep its mock alive in a local for the whole test.
@Suite struct AppModelKeyboardTests {
    /// Records calls; lanes with the given item counts.
    final class MockNavigable: KeyboardNavigable {
        let laneItems: [Int]
        var moveItemCalls: [(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int)] = []

        init(laneItems: [Int]) { self.laneItems = laneItems }

        var navLaneCount: Int { laneItems.count }
        func navItemCount(lane: Int) -> Int {
            laneItems.indices.contains(lane) ? laneItems[lane] : 0
        }
        func navMove(lane: Int, item: Int) -> Bool { true }
        func navMoveItem(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int) -> Bool {
            moveItemCalls.append((lane, item, toLaneDelta, itemDelta))
            return true
        }
        func navOpenDetail(lane: Int, item: Int) {}
        func navBeginRename(lane: Int, item: Int) {}
    }

    private func makeModel(navigable: KeyboardNavigable) -> AppModel {
        let model = AppModel()
        model.navigable = { [weak navigable] in navigable }
        model.clampSelection()
        return model
    }

    private func key(_ chars: String, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? [.shift] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: 0
        )!
    }

    // MARK: Cursor movement

    @Test func jMovesCursorDownAndClampsAtLastItem() {
        let mock = MockNavigable(laneItems: [3])
        let model = makeModel(navigable: mock)
        #expect(model.handleKey(key("j")))
        #expect(model.selectedItem == 1)
        model.handleKey(key("j")); model.handleKey(key("j"))
        #expect(model.selectedItem == 2, "cursor must stop at the last item")
    }

    @Test func kAtTopKeepsCursorAtZero() {
        let mock = MockNavigable(laneItems: [3])
        let model = makeModel(navigable: mock)
        model.handleKey(key("k"))
        #expect(model.selectedItem == 0, "k at the top must not move above the first item")
    }

    @Test func hMovesToLeftLaneAndLClampsAtLastLane() {
        let mock = MockNavigable(laneItems: [2, 2])
        let model = makeModel(navigable: mock)
        model.handleKey(key("l"))
        #expect(model.selectedLane == 1)
        model.handleKey(key("l"))
        #expect(model.selectedLane == 1, "l at the last lane must not overflow")
        model.handleKey(key("h"))
        #expect(model.selectedLane == 0)
        model.handleKey(key("h"))
        #expect(model.selectedLane == 0, "h at the first lane must not underflow")
    }

    @Test func laneSwitchPreservesApproximateVerticalPositionAndClamps() {
        let mock = MockNavigable(laneItems: [4, 1])
        let model = makeModel(navigable: mock)
        model.handleKey(key("j"))
        model.handleKey(key("j"))
        #expect(model.selectedItem == 2)
        model.handleKey(key("l"))
        #expect(model.selectedItem == 0, "vertical position must clamp to the new lane's count")
    }

    @Test func gKeyJumpsToLastItemAndDoubleGToFirst() {
        let mock = MockNavigable(laneItems: [5])
        let model = makeModel(navigable: mock)
        model.handleKey(key("G", shift: true))
        #expect(model.selectedItem == 4)
        model.handleKey(key("g"))
        #expect(model.handleKey(key("g")), "second g must register as gg")
        #expect(model.selectedItem == 0, "gg must jump to the first item")
    }

    @Test func digitKeysJumpToLane() {
        let mock = MockNavigable(laneItems: [1, 1, 1])
        let model = makeModel(navigable: mock)
        model.handleKey(key("3"))
        #expect(model.selectedLane == 2)
        #expect(model.selectedItem == 0)
        model.handleKey(key("9"))
        #expect(model.selectedLane == 2, "jump beyond existing lanes must clamp to the last lane")
    }

    // MARK: Item movement (shift keys)

    @Test func shiftJInvokesMoveItemWithPositiveItemDelta() {
        let mock = MockNavigable(laneItems: [3, 3])
        let model = makeModel(navigable: mock)
        #expect(mock.moveItemCalls.isEmpty)
        #expect(model.handleKey(key("J", shift: true)))
        #expect(mock.moveItemCalls.count == 1)
        #expect(mock.moveItemCalls[0].toLaneDelta == 0)
        #expect(mock.moveItemCalls[0].itemDelta == 1)
    }

    @Test func shiftLInvokesMoveItemToAdjacentLane() {
        let mock = MockNavigable(laneItems: [3, 3])
        let model = makeModel(navigable: mock)
        #expect(model.handleKey(key("L", shift: true)))
        #expect(mock.moveItemCalls.count == 1)
        #expect(mock.moveItemCalls[0].toLaneDelta == 1)
        #expect(model.selectedLane == 1, "cursor follows the moved item")
    }

    // MARK: `dd` deletion

    @Test func ddWithinTimeoutPresentsDeleteConfirmation() {
        let mock = MockNavigable(laneItems: [2])
        let model = makeModel(navigable: mock)
        let task = TodoTask(id: 1, laneID: 1, title: "T", notes: "", position: 0, createdAt: Date(), completedAt: nil)
        model.resolveDetail = { _ in .localTask(task) }
        #expect(model.handleKey(key("d")))
        #expect(model.deleteTarget == nil, "single d must not prompt yet")
        #expect(model.handleKey(key("d")))
        #expect(model.deleteTarget != nil, "second d within the window must prompt for confirmation")
    }

    @Test func dThenOtherKeyThenDDoesNotDelete() {
        let mock = MockNavigable(laneItems: [2])
        let model = makeModel(navigable: mock)
        model.handleKey(key("d"))
        model.handleKey(key("j")) // interrupts the sequence
        model.handleKey(key("d"))
        #expect(model.deleteTarget == nil, "an interrupted dd must not prompt")
    }

    @Test func ddOnEmptyLaneDoesNotDelete() {
        let mock = MockNavigable(laneItems: [0])
        let model = makeModel(navigable: mock)
        model.handleKey(key("d"))
        model.handleKey(key("d"))
        #expect(model.deleteTarget == nil, "no cursor item means nothing to delete")
    }

    @Test func surfaceWithoutDeleteSupportDoesNotDelete() {
        final class NoDelete: KeyboardNavigable {
            var navLaneCount: Int { 1 }
            func navItemCount(lane: Int) -> Int { 2 }
            func navMove(lane: Int, item: Int) -> Bool { true }
            func navMoveItem(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int) -> Bool { true }
            func navOpenDetail(lane: Int, item: Int) {}
            func navBeginRename(lane: Int, item: Int) {}
        }
        let model = makeModel(navigable: NoDelete())
        model.handleKey(key("d"))
        let consumed = model.handleKey(key("d"))
        #expect(consumed, "dd on a surface without a resolvable item is consumed but does nothing")
        #expect(model.deleteTarget == nil)
    }

    // MARK: Detail + toggles

    @Test func enterOpensDetailForCursorItem() {
        let mock = MockNavigable(laneItems: [2])
        let model = makeModel(navigable: mock)
        #expect(model.handleKey(key("\r")))
        #expect(model.detailTarget == CursorPosition(lane: 0, item: 0))
    }

    @Test func enterOnEmptyLaneDoesNotOpenDetail() {
        let mock = MockNavigable(laneItems: [0])
        let model = makeModel(navigable: mock)
        #expect(model.handleKey(key("\r")))
        #expect(model.detailTarget == nil, "no item under the cursor means no detail sheet")
    }

    @Test func questionMarkTogglesHelpOverlay() {
        let mock = MockNavigable(laneItems: [1])
        let model = makeModel(navigable: mock)
        model.handleKey(key("?"))
        #expect(model.showHelp)
        model.handleKey(key("?"))
        #expect(!model.showHelp)
    }

    @Test func nTogglesQuickAddForSelectedLaneAndEscapeClearsIt() {
        let mock = MockNavigable(laneItems: [1])
        let model = makeModel(navigable: mock)
        model.handleKey(key("n"))
        #expect(model.quickAddLane == 0)
        model.handleKey(key("n"))
        #expect(model.quickAddLane == nil, "second n toggles the field off")
        model.handleKey(key("n"))
        model.handleKey(key("\u{1b}"))
        #expect(model.quickAddLane == nil, "Esc must clear the quick-add state")
    }

    // MARK: Event routing

    @Test func shouldInterceptIsFalseForCommandModifiedKeys() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: 0
        )!
        #expect(!KeyboardRouter.shouldIntercept(event), "Cmd-Q etc. must reach the system")
    }

    @Test func handleKeyPassesThroughUnknownKeys() {
        let mock = MockNavigable(laneItems: [1])
        let model = makeModel(navigable: mock)
        #expect(!model.handleKey(key("x")), "unmapped keys must not be consumed")
        #expect(!model.handleKey(key("w")), "window keys stay free for future use")
    }
}