import SwiftUI
import AppKit

// Two tabs side by side, Arc's way: each a rounded card on the window's own
// colour with a little room between them, and the side you last clicked in
// is the side the keys go to. ⌥⌘S puts a new tab beside the one you are on;
// the two stay a pair, side by side in the row, until ⌘W, ⌥⌘S or closing
// one of them ends it.
// Picking another tab shows that tab alone; picking either of the pair
// shows both again.
//
// Off unless asked for, in Settings › General.
//
// Both sides are ordinary tabs in the row. The pairs only remember which
// tabs go together; the pair on screen is the one the tab in front is in,
// and the side with the keys is that tab, `activeID` — so everything that
// acts on the tab in front acts on that side without knowing a split
// exists. Nothing here goes into the session: after a restart the two are
// two tabs again, still side by side.

/// Which two tabs share the window. The side with the keys is not kept here:
/// it is whichever of the two is in front — one fact, rather than two that
/// could come to disagree.
struct Split: Equatable {
    enum Pane { case primary, secondary }

    /// The room around each side while two share the window: at the
    /// window's edges and between the two.
    static let gap: CGFloat = 8
    /// The divider itself, in the middle of the room between the two: the
    /// rest of that room is inside each side, where the ring of the side
    /// with the keys has space to be drawn rather than being cut off at the
    /// side's edge.
    static let seam: CGFloat = 2
    /// The corners of a side, as a card.
    static let radius: CGFloat = 10

    /// The left side.
    let primary: Tab.ID
    /// The right side.
    let secondary: Tab.ID

    func contains(_ id: Tab.ID?) -> Bool { id == primary || id == secondary }

    func pane(of id: Tab.ID) -> Pane? {
        id == primary ? .primary : id == secondary ? .secondary : nil
    }

    func tab(_ pane: Pane) -> Tab.ID { pane == .primary ? primary : secondary }

    /// The other side from `id`, when `id` is one of the two.
    func partner(of id: Tab.ID) -> Tab.ID? {
        id == primary ? secondary : id == secondary ? primary : nil
    }

    /// The same two sides with `old` swapped for `new` — a page that crossed
    /// between the web and an extension's own pages is a new tab in the old
    /// one's place, and the side it was on is still that side.
    func swapping(_ old: Tab.ID, for new: Tab.ID) -> Split {
        Split(primary: primary == old ? new : primary, secondary: secondary == old ? new : secondary)
    }

    /// The row with `moving` carried to `target`, as the tab being dragged
    /// asks with every move of the hand — or nil when nothing should move.
    ///
    /// A pair is one piece: its two tabs go together, in their order. Any
    /// tab stops only between pieces, never inside a pair, and never below
    /// `floor`, where the pinned block ends. Going right it stops at the last
    /// edge the target has reached; going left, at the first. So a target
    /// inside a pair's width moves nothing, and asking again changes nothing
    /// — a tab that jumped past a pair when the hand reached its middle, and
    /// back when it hadn't passed it yet, would jump back and forth on every
    /// move of the hand.
    static func carry(_ moving: Tab.ID, to target: Int, in row: [Tab.ID], pairs: [Split], floor: Int) -> [Tab.ID]? {
        var pieces: [[Tab.ID]] = []
        for id in row {
            if let pair = pairs.first(where: { $0.secondary == id }), pieces.last == [pair.primary] {
                pieces[pieces.count - 1].append(id)
            } else {
                pieces.append([id])
            }
        }
        guard let at = pieces.firstIndex(where: { $0.contains(moving) }) else { return nil }
        let piece = pieces.remove(at: at)
        let within = piece.firstIndex(of: moving) ?? 0
        var edges: [Int] = [0]
        var sum = 0
        for other in pieces {
            sum += other.count
            edges.append(sum)
        }
        let start = edges[at]
        let wanted = max(floor, target - within)
        let usable = edges.filter { $0 >= floor }
        let edge = wanted > start ? usable.last(where: { $0 <= wanted }) : usable.first(where: { $0 >= wanted })
        guard let edge, edge != start, let slot = edges.firstIndex(of: edge) else { return nil }
        pieces.insert(piece, at: slot)
        return pieces.flatMap { $0 }
    }
}

extension Browser {
    /// The pair on screen: the one the tab in front is in.
    var split: Split? { prefs.splitView ? pair(of: activeID) : nil }

    /// The pair a tab is in, if it is in one.
    func pair(of id: Tab.ID?) -> Split? {
        guard let id else { return nil }
        return pairs.first { $0.contains(id) }
    }

    /// Whatever pair `id` is in, ended: the tab is going, or being pinned.
    func unpair(_ id: Tab.ID) {
        pairs.removeAll { $0.contains(id) }
    }

    /// A side's own controls (see SideControls). Close: that side's tab
    /// closes, as ⌘W on it does, and the other side takes the window.
    func closeSide(_ pane: Split.Pane) {
        guard let split, let tab = tabs.first(where: { $0.id == split.tab(pane) }) else { return }
        close(tab)
    }

    /// The two sides the other way round — in the row too, where the left
    /// one comes first — the tab with the keys keeping them.
    func swapSides() {
        guard let split, let left = tabs.first(where: { $0.id == split.primary }),
              let right = tabs.first(where: { $0.id == split.secondary }) else { return }
        put(right, beside: left, before: true)
        pairs = pairs.map { $0 == split ? Split(primary: split.secondary, secondary: split.primary) : $0 }
    }

    /// One side on its own: it takes the keys and the pair ends, both tabs
    /// staying in the row.
    func alone(_ pane: Split.Pane) {
        focus(pane)
        unsplit()
    }

    /// A place in the row a new tab can take: never between the two tabs of
    /// a pair, but just after them.
    func slot(_ index: Int) -> Int {
        let index = min(max(0, index), tabs.count)
        guard index > 0, index < tabs.count,
              pairs.contains(where: { $0.primary == tabs[index - 1].id && $0.secondary == tabs[index].id })
        else { return index }
        return index + 1
    }

    /// The side with the keys, while there is a split.
    var focusedPane: Split.Pane? {
        guard let split, let id = activeID else { return nil }
        return split.pane(of: id)
    }

    /// The two tabs on screen, left and right. Nil unless the switch is on and
    /// both are still in the row: a pair left behind by something unforeseen
    /// shows one page, never a hole where the other was.
    var shownSplit: (primary: Tab, secondary: Tab)? {
        guard prefs.splitView, let split,
              let left = tabs.first(where: { $0.id == split.primary }),
              let right = tabs.first(where: { $0.id == split.secondary })
        else { return nil }
        return (left, right)
    }

    /// ⌥⌘S. A new tab beside this one, or the pair on screen ended.
    func toggleSplit() {
        if split != nil {
            unsplit()
            return
        }
        // A pinned tab lives in its own block and never pairs (see the
        // pinned grid): there is nowhere beside it for a partner to sit.
        guard prefs.splitView, let here = active, here.pin == nil else { return }
        closePeek()
        closeFind()
        cancelTabEdit()
        let beside = partner(for: here)
        pairs.append(Split(primary: here.id, secondary: beside.id))
        focus(.secondary)
    }

    /// The pair on screen ended: the side with the keys keeps the window, and
    /// both tabs stay in the row.
    func unsplit() {
        guard let split else { return }
        pairs.removeAll { $0 == split }
    }

    /// The keys to one side. Not `select(_:)`: the side being left is still
    /// on screen, so its video is not lifted into the floating window and
    /// nothing of it is put away.
    func focus(_ pane: Split.Pane) {
        guard let split, activeID != split.tab(pane) else { return }
        // Coming back to a side whose video is out brings it home, as
        // picking its tab does.
        if floating == split.tab(pane) { land() }
        closePeek()
        closeFind()
        cancelTabEdit()
        dropChoice()
        activeID = split.tab(pane)
        editing = false
        typed = ""
        // A blank side has its field standing; the keys go into it, as ⌘T's do.
        if active?.isBlank == true { askFocus() }
    }

    /// The new side, made as ⌘T makes a tab — an extension's new tab page if
    /// one was allowed, private beside a private tab and in its store, blank
    /// otherwise — and put in the row just after `here`.
    private func partner(for here: Tab) -> Tab {
        if !here.shy, #available(macOS 15.4, *), let page = Extensions.shared.newTabPage {
            return open(page, foreground: false)
        }
        let tab = here.shy
            ? Tab(shy: true, configuration: Web.configuration(shy: true, store: here.store))
            : Tab()
        prepare(tab)
        insert(tab, at: placeForNew())
        return tab
    }
}

/// One page and what floats over it — the find bar, the list of saved
/// sign-ins — the same whether it has the window to itself or shares it.
struct Pane: View {
    @ObservedObject var browser: Browser
    let tab: Tab
    /// This side has the keys. Always, with the window to itself.
    var focused = true
    /// Which side of a split this is; nil with the window to itself. Sharing
    /// the window, it is a card, the field stands in it rather than over the
    /// window, and the side with the keys is ringed.
    var side: Split.Pane? = nil

    private var shared: Bool { side != nil }

    var body: some View {
        if let side {
            card(content, on: side)
        } else {
            content
        }
    }

    /// A side of a split as a card on the window's own colour: the page
    /// clipped to its rounded shape, a hairline at its edge, and a soft
    /// shadow cast by a plain shape behind it — never by the live page,
    /// which is not drawn again for it. The side with the keys has a quiet
    /// ring; the pages themselves are never tinted.
    private func card(_ page: some View, on side: Split.Pane) -> some View {
        let shape = RoundedRectangle(cornerRadius: Split.radius, style: .continuous)
        return page
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false))
            .overlay {
                // Just outside the card, on the window's own colour: drawn
                // over the page's edge it vanished wherever the page and the
                // ink were both light, as in dark mode.
                if focused {
                    RoundedRectangle(cornerRadius: Split.radius + 2.5, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5)
                        .padding(-2.5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: focused)
            .background(shape.fill(Palette.ground).shadow(color: .black.opacity(0.08), radius: 6, y: 1))
            .padding(.vertical, Split.gap)
            .padding(side == .primary ? .leading : .trailing, Split.gap)
            .padding(side == .primary ? .trailing : .leading, (Split.gap - Split.seam) / 2)
    }

    @ViewBuilder
    private var content: some View {
        Page(tab: tab)
            .overlay(alignment: .topTrailing) {
                if focused, browser.finding {
                    FindBar(browser: browser)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                if let asked = browser.suggesting, asked.tab == tab.id {
                    AccountList(browser: browser, asked: asked)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: browser.suggesting)
            .overlay {
                if shared, focused, browser.fieldShowing {
                    GeometryReader { room in
                        // The whole side to stand in, so it is centred there
                        // as the window's field is in the window.
                        Omnibox(browser: browser, over: !tab.isBlank,
                                width: min(Metrics.fieldWidth, room.size.width - 48))
                            .frame(width: room.size.width, height: room.size.height)
                    }
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
            // A side is its own SwiftUI world, out of reach of the window's
            // animation for the field: it comes and goes here on the same one.
            .animation(shared ? (browser.fieldShowing ? Motion.settle : Motion.quick) : nil, value: browser.fieldShowing)
    }
}

/// The two sides, with AppKit's own divider between them.
struct SplitStage: NSViewRepresentable {
    let browser: Browser
    let primary: Tab
    let secondary: Tab
    let focus: Split.Pane?

    func makeNSView(context: Context) -> SplitHost {
        SplitHost(browser: browser, left: sides.0, right: sides.1)
    }

    func updateNSView(_ host: SplitHost, context: Context) {
        host.show(sides.0, sides.1)
    }

    private var sides: (Pane, Pane) {
        (Pane(browser: browser, tab: primary, focused: focus == .primary, side: .primary),
         Pane(browser: browser, tab: secondary, focused: focus == .secondary, side: .secondary))
    }
}

final class SplitHost: NSSplitView, NSSplitViewDelegate {
    /// The one on screen, for the bench to click through as AppKit would.
    static weak var current: SplitHost?

    private weak var browser: Browser?
    private let left: NSHostingView<Pane>
    private let right: NSHostingView<Pane>
    private var watcher: Any?
    /// Halved once, the first time there is a width to halve; after that the
    /// divider stays where it was dragged.
    private var halved = false
    /// How wide the divider answers the pointer: a little past the gap
    /// on either side, so grabbing it doesn't take aim.
    static let grab: CGFloat = 12
    private let handle = GrabHandle()
    private var tracking: [NSTrackingArea] = []
    /// Each side's own controls (see SideControls), over the top of its
    /// card: views of their own above both sides, so a click on them is
    /// theirs rather than the page's underneath.
    private let pills: [PillHost]
    /// The side whose controls are showing, if any.
    private(set) var pillShown: Split.Pane? { didSet { if pillShown != oldValue { showPills() } } }
    private var resigned: Any?
    private var hovering = false { didSet { if hovering != oldValue { showHandle() } } }
    private var dragging = false { didSet { if dragging != oldValue { showHandle() } } }
    /// Where the line was when the pointer was last asked about.
    private var lineAt: CGFloat = -1

    init(browser: Browser, left: Pane, right: Pane) {
        self.browser = browser
        self.left = NSHostingView(rootView: left)
        self.right = NSHostingView(rootView: right)
        self.pills = [Split.Pane.primary, .secondary].map { PillHost(rootView: SideControls(browser: browser, side: $0)) }
        super.init(frame: .zero)
        // Sized by the divider, never by what they hold — and reaching up
        // under the title bar as the page alone does, rather than starting
        // below it with a band of nothing above.
        for side in [self.left, self.right] {
            side.sizingOptions = []
            side.safeAreaRegions = []
        }
        isVertical = true
        dividerStyle = .thin
        delegate = self
        // The two sides are the split; the handle only sits on its line.
        arrangesAllSubviews = false
        addArrangedSubview(self.left)
        addArrangedSubview(self.right)
        addSubview(handle)
        for pill in pills {
            pill.alphaValue = 0
            pill.isHidden = true
            addSubview(pill)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ left: Pane, _ right: Pane) {
        self.left.rootView = left
        self.right.rootView = right
    }

    override var dividerThickness: CGFloat { Split.seam }

    /// Nothing: the room between the cards is the window's own colour
    /// showing through — whatever it is, black too while a page fills the
    /// screen — with no channel and no line.
    override func drawDivider(in rect: NSRect) {}

    override func layout() {
        super.layout()
        if !halved, bounds.width > 0 {
            halved = true
            setPosition(halfway, ofDividerAt: 0)
        }
        divided()
    }

    /// Where the divider goes for two equal sides: the gap in the middle,
    /// not its left edge.
    private var halfway: CGFloat { (bounds.width - dividerThickness) / 2 }

    /// The divider's grab area, in this view.
    var grabRect: NSRect {
        guard arrangedSubviews.count == 2 else { return .zero }
        let line = arrangedSubviews[0].frame.maxX + dividerThickness / 2
        return NSRect(x: line - Self.grab / 2, y: 0, width: Self.grab, height: bounds.height)
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt index: Int) -> NSRect {
        drawn.insetBy(dx: -(Self.grab - drawn.width) / 2, dy: 0)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) { divided() }

    /// The two-way cursor the moment the pointer is on the grab, and at
    /// either limit too — not the one-way cursor the split view would pick
    /// there.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(grabRect, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.forEach(removeTrackingArea)
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        // The grab, the gap above each card that shows its controls, and the
        // controls themselves, which keep them showing.
        tracking = [NSTrackingArea(rect: grabRect, options: options, owner: self, userInfo: ["what": "grab"])]
            + [Split.Pane.primary, .secondary].flatMap { side in
                [NSTrackingArea(rect: band(side), options: options, owner: self, userInfo: ["what": "pill"]),
                 NSTrackingArea(rect: pills[side == .primary ? 0 : 1].frame, options: options, owner: self, userInfo: ["what": "pill"])]
            }
        tracking.forEach(addTrackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["what"] as? String == "grab" { hover(true) } else { refreshPill(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["what"] as? String == "grab" { hover(false) } else { refreshPill(at: convert(event.locationInWindow, from: nil)) }
    }

    /// Which side's controls show for the pointer at `point`, in this view:
    /// the side whose gap above the card it is in, or the side whose controls
    /// are already showing, while it is on them. A pointer coming up from the
    /// page into their spot shows nothing — the page there is still the
    /// page's. Never the side with the keys while its find bar is up, which
    /// the controls would cover.
    func refreshPill(at point: NSPoint) {
        var showing = [Split.Pane.primary, .secondary].first { side in
            band(side).contains(point) || (pillShown == side && pills[side == .primary ? 0 : 1].frame.contains(point))
        }
        if let side = showing, browser?.finding == true, browser?.focusedPane == side { showing = nil }
        pillShown = showing
    }

    /// Straight to a side's controls, or none — for the bench.
    func hoverPill(_ side: Split.Pane?) { pillShown = side }
    var pillViews: [NSView] { pills }

    /// Where a side's card is, in this view: its side less the room around it.
    func card(_ side: Split.Pane) -> NSRect {
        guard arrangedSubviews.count == 2 else { return .zero }
        let frame = arrangedSubviews[side == .primary ? 0 : 1].frame
        let inner = (Split.gap - Split.seam) / 2
        return NSRect(x: side == .primary ? frame.minX + Split.gap : frame.minX + inner, y: frame.minY + Split.gap,
                      width: frame.width - Split.gap - inner, height: frame.height - 2 * Split.gap)
    }

    /// The gap above a card, which shows its controls.
    private func band(_ side: Split.Pane) -> NSRect {
        let card = card(side)
        return NSRect(x: card.minX, y: card.minY - Split.gap, width: card.width, height: Split.gap)
    }

    /// Only their alpha moves, one side's controls in as the other's go —
    /// and once gone they are hidden outright, with no tooltip or button left
    /// for the pointer or VoiceOver to find.
    private func showPills() {
        for (side, pill) in zip([Split.Pane.primary, .secondary], pills) {
            let live = side == pillShown
            pill.live = live
            if live { pill.isHidden = false }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                pill.animator().alphaValue = live ? 1 : 0
            }, completionHandler: { [weak pill] in
                MainActor.assumeIsolated {
                    if let pill, !pill.live { pill.isHidden = true }
                }
            })
        }
    }

    /// The pointer on the grab, or off it — from the tracking area, or the bench.
    func hover(_ on: Bool) { hovering = on }
    var handleAlpha: CGFloat { handle.alphaValue }

    /// A double-click on the grab puts the line back in the middle, in one
    /// step: each page is laid out once, at its final width. Anything else
    /// is the split view's own drag.
    override func mouseDown(with event: NSEvent) {
        guard grabRect.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            setPosition(halfway, ofDividerAt: 0)
            return
        }
        dragging = true
        // The split view follows the hand from here until it lets go.
        super.mouseDown(with: event)
        dragging = false
    }

    /// The handle, the cursor and the tracking follow the line wherever it
    /// went — and when it went somewhere, whether the pointer is on it is
    /// asked again: a tracking area made anew says nothing about a pointer
    /// that was already there, or has just been left behind by a line that
    /// jumped, as a double-click makes it.
    private func divided() {
        let line = grabRect
        // Narrow enough to stay clear of the ring on the side with the keys.
        handle.frame = NSRect(x: line.midX - 1.5, y: line.midY - 18, width: 3, height: 36)
        for (side, pill) in zip([Split.Pane.primary, .secondary], pills) {
            let card = card(side)
            let size = pill.fittingSize
            pill.frame = NSRect(x: card.midX - size.width / 2, y: card.minY + SideControls.drop - SideControls.room,
                                width: size.width, height: size.height)
        }
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
        guard line.midX != lineAt else { return }
        lineAt = line.midX
        if !dragging, let window {
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovering = line.contains(pointer)
            refreshPill(at: pointer)
        }
    }

    /// Only the handle's alpha moves — nothing is laid out again for it.
    private func showHandle() {
        let alpha: CGFloat = dragging ? 1 : hovering ? 0.7 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            handle.animator().alphaValue = alpha
        }
    }

    /// Neither side dragged away to nothing: 240 points each, or a third of
    /// the room when the window is too narrow for that.
    private var least: CGFloat { min(240, bounds.width / 3) }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, least)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, bounds.width - least)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let watcher { NSEvent.removeMonitor(watcher) }
        watcher = nil
        guard window != nil else {
            if SplitHost.current === self { SplitHost.current = nil }
            if let resigned { NotificationCenter.default.removeObserver(resigned) }
            resigned = nil
            return
        }
        SplitHost.current = self
        // Nothing stays showing for a pointer this window no longer follows.
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
        resigned = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverPill(nil) }
        }
        watcher = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.pressed(event)
            // Never swallowed: the press goes on to the link, the button or
            // the field under it, in the same click that gave its side the keys.
            return event
        }
    }

    /// A press anywhere in the app, before AppKit hands it to the view under
    /// it. One on a side gives that side the keys — once the press has been
    /// delivered, since moving the keys redraws both sides and a page is not
    /// to be moved under a click still on its way to it.
    func pressed(_ event: NSEvent) {
        guard let window, event.window === window, browser?.peekTab == nil,
              let frame = window.contentView?.superview,
              let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)),
              let pane = side(of: hit)
        else { return }
        DispatchQueue.main.async { [weak browser] in browser?.focus(pane) }
    }

    /// Which side a view is in — nil for the divider, the tabs, or anything
    /// drawn over both.
    func side(of view: NSView) -> Split.Pane? {
        if view.isDescendant(of: left) { return .primary }
        if view.isDescendant(of: right) { return .secondary }
        return nil
    }
}

/// The divider's handle: a small capsule on the line, there only while the
/// pointer is on it or it is being dragged. Drawn by its layer; never clicked.
private final class GrabHandle: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1.5
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.NS.muted.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A side's own controls: a small pill over the top of its card, there
/// while the pointer is along that top (see SplitHost) — close this side,
/// swap the two, or this side on its own.
struct SideControls: View {
    let browser: Browser
    let side: Split.Pane

    /// How far down the card the pointer can be and still show them.
    static let reach: CGFloat = 40
    /// Room around the capsule for its shadow, and how far below the card's
    /// top the capsule sits.
    static let room: CGFloat = 6
    static let drop: CGFloat = 6
    /// A button, and the inset and spacing around it: where they are, for
    /// the bench to click them there.
    static let knob: CGFloat = 24
    static let inset: CGFloat = 3
    static let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: Self.spacing) {
            Knob(symbol: "xmark", help: "Close this side") { browser.closeSide(side) }
            Knob(symbol: "arrow.left.arrow.right", help: "Swap sides") { browser.swapSides() }
            Knob(symbol: "arrow.up.left.and.arrow.down.right", help: "Open on its own") { browser.alone(side) }
        }
        .padding(Self.inset)
        .background(Capsule().fill(Palette.ground).shadow(color: .black.opacity(0.12), radius: 4, y: 1))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(Self.room)
    }

    private struct Knob: View {
        let symbol: String
        let help: String
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: SideControls.knob, height: SideControls.knob)
                    .background(hovering ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
            .onHover { hovering = $0 }
        }
    }
}

/// A side's controls as a view of their own: answering the pointer only
/// while they are showing, so the page under them gets every click otherwise.
final class PillHost: NSHostingView<SideControls> {
    var live = false

    /// Only the capsule itself, not the room left around it for its shadow.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard live, bounds.insetBy(dx: SideControls.room, dy: SideControls.room).contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
