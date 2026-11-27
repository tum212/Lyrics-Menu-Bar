import AppKit
import QuartzCore

// MARK: - Zero-SwiftUI 60 FPS Virtualized CALayer HUD Lyrics Stream

@MainActor
final class HUDLyricsView: NSView {
    private struct WordSpanLayout {
        let startTime: Double
        let endTime: Double
        let startX: CGFloat
        let endX: CGFloat
    }

    private struct SubLineLayout {
        let text: String
        let width: CGFloat
        let height: CGFloat
        let offsetYFromRowTop: CGFloat
        let spans: [WordSpanLayout]
        let startTime: Double
        let endTime: Double
    }

    private struct RowLayout {
        let index: Int
        let lineId: UInt64
        let time: Double
        let endTime: Double
        let isBgVocal: Bool
        let indentX: CGFloat
        let topY: CGFloat
        let totalHeight: CGFloat
        let subLines: [SubLineLayout]
    }

    private final class SubLineSlot {
        let container = CALayer()
        let dimLayer = CALayer()
        let litLayer = CALayer()
        let maskContainer = CALayer()
        let maskSolid = CALayer()
        let maskFeather = CAGradientLayer()

        var cachedKey: String = ""

        init() {
            container.anchorPoint = .zero
            container.masksToBounds = false

            dimLayer.anchorPoint = .zero
            dimLayer.contentsGravity = .bottomLeft

            litLayer.anchorPoint = .zero
            litLayer.contentsGravity = .bottomLeft
            litLayer.isHidden = true

            maskContainer.anchorPoint = .zero
            maskContainer.masksToBounds = false

            maskSolid.anchorPoint = .zero
            maskSolid.backgroundColor = NSColor.white.cgColor
            maskSolid.frame = CGRect(x: -1200, y: 0, width: 1200, height: 32)

            maskFeather.anchorPoint = .zero
            maskFeather.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
            maskFeather.startPoint = CGPoint(x: 0.0, y: 0.5)
            maskFeather.endPoint = CGPoint(x: 1.0, y: 0.5)
            maskFeather.frame = CGRect(x: 0, y: 0, width: 20, height: 32)

            maskContainer.addSublayer(maskSolid)
            maskContainer.addSublayer(maskFeather)
            litLayer.mask = maskContainer

            container.addSublayer(dimLayer)
            container.addSublayer(litLayer)
        }

        func applyScale(_ scale: CGFloat) {
            dimLayer.contentsScale = scale
            litLayer.contentsScale = scale
            maskFeather.contentsScale = scale
        }
    }

    private final class RowSlot {
        let container = CALayer()
        var subSlots: [SubLineSlot] = []
        var assignedRowIndex: Int = -1

        init() {
            container.anchorPoint = .zero
            container.masksToBounds = false
            container.isHidden = true
        }

        func ensureSubSlots(_ count: Int, scale: CGFloat) {
            while subSlots.count < count {
                let sub = SubLineSlot()
                sub.applyScale(scale)
                container.addSublayer(sub.container)
                subSlots.append(sub)
            }
        }
    }

    // Visual Layers
    private let clipLayer = CALayer()
    private let edgeMaskLayer = CAGradientLayer()
    private let emptyLabelLayer = CATextLayer()
    private var rowSlots: [RowSlot] = []
    private var imageCache: [String: CGImage] = [:]

    // Layout & Scroll State
    private var rows: [RowLayout] = []
    private var totalContentHeight: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0
    private var lastLyricsSignature: String = ""
    private var isUnsynced: Bool = false

    private var scrollY: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    private var targetScrollY: CGFloat = 0
    private var activeRowIndex: Int = -1
    private var manualScrollUntil: CFTimeInterval = 0

    // Hover & Tracking
    private var isViewportHovered: Bool = false
    private var hoveredRowIndex: Int = -1
    private var trackingAreaRef: NSTrackingArea?
    private var backingScale: CGFloat = 2.0

    var onSeek: ((Int, LyricLineModel) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        clipLayer.anchorPoint = .zero
        clipLayer.masksToBounds = true
        edgeMaskLayer.anchorPoint = .zero
        edgeMaskLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.clear.cgColor
        ]
        // Unflipped: bottom 0..0.15 fade, top 0.92..1.0 fade
        edgeMaskLayer.locations = [0.0, 0.15, 0.92, 1.0]
        edgeMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        edgeMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        clipLayer.mask = edgeMaskLayer
        layer?.addSublayer(clipLayer)

        emptyLabelLayer.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        emptyLabelLayer.fontSize = 18
        emptyLabelLayer.alignmentMode = .center
        emptyLabelLayer.foregroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
        emptyLabelLayer.contentsScale = backingScale
        emptyLabelLayer.isHidden = false
        layer?.addSublayer(emptyLabelLayer)

        for _ in 0..<18 {
            let slot = RowSlot()
            clipLayer.addSublayer(slot.container)
            rowSlots.append(slot)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handlePrefsChanged), name: UserDefaults.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handlePrefsChanged), name: Notification.Name("UltraLightModeChanged"), object: nil)
        nc.addObserver(self, selector: #selector(handlePlaybackSeek), name: LyricsCoreEngine.playbackDidSeekNotification, object: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func handlePrefsChanged() {
        renderNow()
    }

    @objc private func handlePlaybackSeek() {
        manualScrollUntil = 0
        snapScrollToActive()
        renderNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        guard abs(newScale - backingScale) > 0.01 else { return }
        backingScale = newScale
        imageCache.removeAll(keepingCapacity: true)
        emptyLabelLayer.contentsScale = newScale
        for s in rowSlots {
            for sub in s.subSlots {
                sub.applyScale(newScale)
                sub.cachedKey = ""
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = bounds
        edgeMaskLayer.frame = bounds
        emptyLabelLayer.frame = CGRect(x: 0, y: (bounds.height - 26) / 2.0, width: bounds.width, height: 26)
        CATransaction.commit()

        if abs(bounds.width - lastLayoutWidth) > 1.0 {
            rebuildLayout()
            snapScrollToActive()
            renderNow()
        }
    }

    func invalidateLyricsAndScrollReset() {
        imageCache.removeAll(keepingCapacity: true)
        rows.removeAll()
        activeRowIndex = -1
        scrollY = 0
        scrollVelocity = 0
        targetScrollY = 0
        manualScrollUntil = 0
        hoveredRowIndex = -1
        rebuildLayout()
        snapScrollToActive()
        renderNow()
    }

    func snapScrollToActive() {
        let (idx, _) = LyricsCoreEngine.shared.resolveHUDActiveIndex()
        activeRowIndex = idx
        if idx >= 0 && idx < rows.count && !isUnsynced {
            let row = rows[idx]
            let desired = (row.topY + row.totalHeight * 0.5) - bounds.height * 0.38
            let maxScroll = max(0, totalContentHeight - bounds.height)
            targetScrollY = min(maxScroll, max(0, desired))
            scrollY = targetScrollY
            scrollVelocity = 0
        }
    }

    func renderNow() {
        let eng = LyricsCoreEngine.shared
        renderFrame(
            currentTime: eng.currentTime(),
            deltaTime: 0.016,
            isPlaying: eng.isPlaying
        )
    }

    // MARK: - Font & Layout Cache

    private static func makeFont(isBgVocal: Bool) -> NSFont {
        let size: CGFloat = isBgVocal ? 15.0 : 20.0
        let base = NSFont.systemFont(ofSize: size, weight: isBgVocal ? .semibold : .bold)
        if isBgVocal {
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }
        return base
    }

    private func rebuildLayout() {
        let engine = LyricsCoreEngine.shared
        let lines = engine.lyrics
        let w = bounds.width
        guard w > 40 else { return }

        let sig = "\(lines.count)_\(lines.first?.id ?? 0)_\(lines.last?.id ?? 0)"
        if sig == lastLyricsSignature && abs(w - lastLayoutWidth) <= 1.0 && !rows.isEmpty {
            return
        }
        lastLyricsSignature = sig
        lastLayoutWidth = w

        rows.removeAll(keepingCapacity: true)
        imageCache.removeAll(keepingCapacity: true)
        for s in rowSlots {
            s.assignedRowIndex = -1
            for sub in s.subSlots { sub.cachedKey = "" }
        }

        isUnsynced = lines.count > 1 && (lines.last?.time ?? 0) == 0
        guard !lines.isEmpty else {
            totalContentHeight = 0
            return
        }

        let horizontalPad: CGFloat = 4.0
        let contentAvailW = max(80.0, w - horizontalPad * 2.0)
        var cursorY: CGFloat = 14.0

        for (idx, line) in lines.enumerated() {
            let isBg = line.isBackgroundVocal
            let indentX: CGFloat = isBg ? 24.0 : 0.0
            let effectiveW = max(80.0, contentAvailW - indentX - 12.0)
            let font = Self.makeFont(isBgVocal: isBg)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let subH: CGFloat = isBg ? 22.0 : 28.0

            var subLines: [SubLineLayout] = []
            if !line.words.isEmpty && !isUnsynced {
                // Wrap using LyricWordModel tokens + measure cumulative span X positions
                var wrappedRows: [[LyricWordModel]] = []
                var curWords: [LyricWordModel] = []
                var curW: CGFloat = 0
                let spaceW = " ".size(withAttributes: attrs).width

                for word in line.words {
                    let wordW = word.text.size(withAttributes: attrs).width
                    let added = curWords.isEmpty ? wordW : (spaceW + wordW)
                    if curW + added > effectiveW && !curWords.isEmpty {
                        wrappedRows.append(curWords)
                        curWords = [word]
                        curW = wordW
                    } else {
                        curWords.append(word)
                        curW += added
                    }
                }
                if !curWords.isEmpty { wrappedRows.append(curWords) }
                if wrappedRows.isEmpty { wrappedRows = [line.words] }

                var subY: CGFloat = 0
                for rw in wrappedRows {
                    var built = ""
                    var spans: [WordSpanLayout] = []
                    for (wi, word) in rw.enumerated() {
                        let prefix = wi == 0 ? "" : built + " "
                        let sx = prefix.isEmpty ? 0.0 : prefix.size(withAttributes: attrs).width
                        built = prefix + word.text
                        let ex = built.size(withAttributes: attrs).width
                        spans.append(WordSpanLayout(startTime: word.startTime, endTime: word.endTime, startX: sx, endX: ex))
                    }
                    let rowW = max(1.0, built.size(withAttributes: attrs).width)
                    subLines.append(SubLineLayout(
                        text: built,
                        width: rowW,
                        height: subH,
                        offsetYFromRowTop: subY,
                        spans: spans,
                        startTime: rw.first?.startTime ?? line.time,
                        endTime: rw.last?.endTime ?? line.endTime
                    ))
                    subY += subH + 4.0
                }
            } else {
                let rawWords = line.text.split(separator: " ").map(String.init)
                var textRows: [String] = []
                var curLine = ""
                for wToken in rawWords {
                    let candidate = curLine.isEmpty ? wToken : "\(curLine) \(wToken)"
                    if candidate.size(withAttributes: attrs).width > effectiveW && !curLine.isEmpty {
                        textRows.append(curLine)
                        curLine = wToken
                    } else {
                        curLine = candidate
                    }
                }
                if !curLine.isEmpty { textRows.append(curLine) }
                if textRows.isEmpty { textRows = [line.text] }

                var subY: CGFloat = 0
                for tRow in textRows {
                    let rw = max(1.0, tRow.size(withAttributes: attrs).width)
                    subLines.append(SubLineLayout(
                        text: tRow,
                        width: rw,
                        height: subH,
                        offsetYFromRowTop: subY,
                        spans: [],
                        startTime: line.time,
                        endTime: line.endTime
                    ))
                    subY += subH + 4.0
                }
            }

            let totalH = max(subH, CGFloat(subLines.count) * subH + CGFloat(max(0, subLines.count - 1)) * 4.0)
            rows.append(RowLayout(
                index: idx,
                lineId: line.id,
                time: line.time,
                endTime: line.endTime,
                isBgVocal: isBg,
                indentX: horizontalPad + indentX,
                topY: cursorY,
                totalHeight: totalH,
                subLines: subLines
            ))
            cursorY += totalH + 6.0
        }
        totalContentHeight = cursorY + 14.0
    }

    // MARK: - 60 FPS Frame Render

    func renderFrame(currentTime: Double, deltaTime: Double, isPlaying: Bool) {
        let engine = LyricsCoreEngine.shared
        let lines = engine.lyrics
        let isUltraLight = AppPerformance.isUltraLightMode

        if lines.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipLayer.isHidden = true
            emptyLabelLayer.isHidden = false
            emptyLabelLayer.string = engine.isLyricsLoading ? "Loading lyrics..." : (isPlaying ? "♪" : "")
            for s in rowSlots { s.container.isHidden = true }
            CATransaction.commit()
            return
        }

        if rows.count != lines.count || abs(bounds.width - lastLayoutWidth) > 1.0 {
            rebuildLayout()
        }

        let (resolvedIdx, unsyncedFlag) = engine.resolveHUDActiveIndex()
        isUnsynced = unsyncedFlag
        activeRowIndex = resolvedIdx

        let maxScroll = max(0.0, totalContentHeight - bounds.height)
        let nowMedia = CACurrentMediaTime()
        if !isUnsynced && activeRowIndex >= 0 && activeRowIndex < rows.count && nowMedia >= manualScrollUntil {
            let row = rows[activeRowIndex]
            let anchorOffset = bounds.height * 0.38
            let desired = (row.topY + row.totalHeight * 0.5) - anchorOffset
            targetScrollY = min(maxScroll, max(0.0, desired))
        } else {
            targetScrollY = min(maxScroll, max(0.0, targetScrollY))
        }

        // Critically damped spring scroll (~0.65s Apple Music curve)
        let dt = min(0.05, max(0.001, deltaTime))
        let stiffness: CGFloat = 95.0
        let damping: CGFloat = 19.5
        let force = (targetScrollY - scrollY) * stiffness
        scrollVelocity = (scrollVelocity + force * CGFloat(dt)) * max(0.0, 1.0 - damping * CGFloat(dt))
        scrollY += scrollVelocity * CGFloat(dt)
        if abs(targetScrollY - scrollY) < 0.2 && abs(scrollVelocity) < 0.5 {
            scrollY = targetScrollY
            scrollVelocity = 0
        }

        let viewportH = bounds.height
        let visMinY = scrollY - 48.0
        let visMaxY = scrollY + viewportH + 48.0

        // Collect visible row indices
        var visibleIndices: [Int] = []
        visibleIndices.reserveCapacity(16)
        for (i, row) in rows.enumerated() {
            if row.topY + row.totalHeight >= visMinY && row.topY <= visMaxY {
                visibleIndices.append(i)
                if visibleIndices.count >= rowSlots.count { break }
            } else if row.topY > visMaxY {
                break
            }
        }

        // Rasterize any missing textures for visible rows before Transaction commit
        for rIdx in visibleIndices {
            let row = rows[rIdx]
            let font = Self.makeFont(isBgVocal: row.isBgVocal)
            for (subIdx, sub) in row.subLines.enumerated() {
                let key = "\(row.lineId)_\(subIdx)_\(Int(row.totalHeight))"
                if imageCache[key] == nil {
                    if let cg = rasterizeHUDLine(sub.text, width: sub.width, height: sub.height, font: font, scale: backingScale) {
                        imageCache[key] = cg
                    }
                }
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.isHidden = false
        emptyLabelLayer.isHidden = true

        // Precompute fallback per-subline progress if line has no word spans
        for (slotIdx, slot) in rowSlots.enumerated() {
            guard slotIdx < visibleIndices.count else {
                slot.container.isHidden = true
                slot.assignedRowIndex = -1
                continue
            }

            let rIdx = visibleIndices[slotIdx]
            let row = rows[rIdx]
            slot.assignedRowIndex = rIdx
            slot.container.isHidden = false

            let visTop = row.topY - scrollY
            let macY = viewportH - visTop - row.totalHeight
            slot.container.frame = CGRect(x: row.indentX, y: macY, width: bounds.width - row.indentX, height: row.totalHeight)

            let isActive = (!isUnsynced && rIdx == activeRowIndex)
            let isPast = (!isUnsynced && activeRowIndex >= 0 && rIdx < activeRowIndex)
            let isRowHovered = (rIdx == hoveredRowIndex) || isViewportHovered
            let focusMode = UserDefaults.standard.object(forKey: AppSettingKey.lyricsFocusMode) as? Bool ?? true

            let dimAlpha: Float
            if isUnsynced {
                dimAlpha = (rIdx == hoveredRowIndex) ? 1.0 : (isViewportHovered ? 0.90 : 0.85)
            } else if isActive {
                dimAlpha = 0.35
            } else if isRowHovered {
                dimAlpha = 0.78
            } else if isPast {
                dimAlpha = focusMode ? 0.22 : 0.42
            } else {
                dimAlpha = focusMode ? 0.42 : 0.68
            }

            slot.ensureSubSlots(row.subLines.count, scale: backingScale)

            let totalChars = max(1, row.subLines.reduce(0) { $0 + $1.text.count })
            var charAcc = 0
            let fallbackActiveDur = max(0.1, row.endTime - row.time)
            let fallbackLocalP = min(1.0, max(0.0, (currentTime - row.time) / fallbackActiveDur))

            for (subIdx, subSlot) in slot.subSlots.enumerated() {
                guard subIdx < row.subLines.count else {
                    subSlot.container.isHidden = true
                    continue
                }
                let sub = row.subLines[subIdx]
                subSlot.container.isHidden = false

                let subMacY = row.totalHeight - sub.offsetYFromRowTop - sub.height
                let texW = ceil(sub.width) + 4.0
                subSlot.container.frame = CGRect(x: 0, y: subMacY, width: texW, height: sub.height)
                subSlot.dimLayer.frame = CGRect(x: 0, y: 0, width: texW, height: sub.height)
                subSlot.litLayer.frame = CGRect(x: 0, y: 0, width: texW, height: sub.height)

                let cacheKey = "\(row.lineId)_\(subIdx)_\(Int(row.totalHeight))"
                if subSlot.cachedKey != cacheKey, let cgImg = imageCache[cacheKey] {
                    subSlot.cachedKey = cacheKey
                    subSlot.dimLayer.contents = cgImg
                    subSlot.litLayer.contents = cgImg
                    subSlot.dimLayer.contentsScale = backingScale
                    subSlot.litLayer.contentsScale = backingScale
                }

                subSlot.dimLayer.opacity = dimAlpha

                if isActive {
                    let fadeW: CGFloat = 20.0
                    let leadX: CGFloat
                    let isRowSinging: Bool
                    let isRowSung: Bool

                    if !sub.spans.isEmpty {
                        if currentTime < sub.startTime {
                            leadX = -fadeW
                            isRowSinging = false
                            isRowSung = false
                        } else if currentTime >= sub.endTime {
                            leadX = sub.width + fadeW
                            isRowSinging = false
                            isRowSung = true
                        } else {
                            var foundX = sub.width
                            for span in sub.spans {
                                if currentTime >= span.startTime && currentTime < span.endTime {
                                    let dur = max(0.05, span.endTime - span.startTime)
                                    let wp = CGFloat((currentTime - span.startTime) / dur)
                                    foundX = span.startX + (span.endX - span.startX) * wp
                                    break
                                } else if currentTime < span.startTime {
                                    foundX = span.startX
                                    break
                                }
                            }
                            leadX = foundX
                            isRowSinging = true
                            isRowSung = false
                        }
                    } else {
                        let ls = Double(charAcc) / Double(totalChars)
                        charAcc += sub.text.count
                        let le = Double(charAcc) / Double(totalChars)
                        let lp = min(1.0, max(0.0, (fallbackLocalP - ls) / max(0.001, le - ls)))
                        leadX = (sub.width + fadeW) * CGFloat(lp) - fadeW
                        isRowSinging = lp > 0.0 && lp < 1.0
                        isRowSung = lp >= 1.0
                    }

                    if leadX + fadeW > 0 {
                        subSlot.litLayer.isHidden = false
                        subSlot.litLayer.opacity = 1.0
                        subSlot.maskContainer.position = CGPoint(x: leadX, y: 0)
                        if !isUltraLight && (isRowSinging || isRowSung) {
                            subSlot.litLayer.shadowColor = NSColor.white.cgColor
                            subSlot.litLayer.shadowOffset = .zero
                            subSlot.litLayer.shadowOpacity = isRowSinging ? 0.60 : 0.30
                            subSlot.litLayer.shadowRadius = isRowSinging ? 5.0 : 2.8
                        } else {
                            subSlot.litLayer.shadowOpacity = 0.0
                        }
                    } else {
                        subSlot.litLayer.isHidden = true
                    }
                } else {
                    subSlot.litLayer.isHidden = true
                    subSlot.litLayer.shadowOpacity = 0.0
                }
            }
        }

        CATransaction.commit()
    }

    // MARK: - Pointer & Scroll Events

    override func scrollWheel(with event: NSEvent) {
        guard !rows.isEmpty else { return }
        manualScrollUntil = CACurrentMediaTime() + 3.5
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14.0
        let maxScroll = max(0.0, totalContentHeight - bounds.height)
        targetScrollY = min(maxScroll, max(0.0, targetScrollY - dy))
        scrollY = targetScrollY
        scrollVelocity = 0
        renderNow()
    }

    override func mouseEntered(with event: NSEvent) {
        isViewportHovered = true
        updateHoveredRow(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        isViewportHovered = true
        updateHoveredRow(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isViewportHovered = false
        if hoveredRowIndex != -1 {
            hoveredRowIndex = -1
            NSCursor.arrow.set()
            renderNow()
        }
    }

    private func rowIndex(at point: NSPoint) -> Int {
        guard bounds.contains(point) else { return -1 }
        let contentY = (bounds.height - point.y) + scrollY
        for row in rows {
            if contentY >= row.topY - 2 && contentY <= row.topY + row.totalHeight + 4 {
                return row.index
            }
        }
        return -1
    }

    private func updateHoveredRow(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = rowIndex(at: pt)
        if idx >= 0 {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        if idx != hoveredRowIndex {
            hoveredRowIndex = idx
            renderNow()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = rowIndex(at: pt)
        let lines = LyricsCoreEngine.shared.lyrics
        guard idx >= 0 && idx < lines.count else { return }
        manualScrollUntil = 0
        onSeek?(idx, lines[idx])
        snapScrollToActive()
        renderNow()
    }

    // MARK: - Direct CGContext Line Rasterizer (1 CGImage per wrapped row)

    private func rasterizeHUDLine(_ text: String, width: CGFloat, height: CGFloat, font: NSFont, scale: CGFloat) -> CGImage? {
        let safeW = ceil(width) + 4.0
        guard safeW > 4.0, height > 2.0 else { return nil }
        let pxW = max(1, Int(ceil(safeW * scale)))
        let pxH = max(1, Int(ceil(height * scale)))

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(true)
        ctx.setShouldSubpixelQuantizeFonts(false)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        let drawY = max(0, (height - sz.height) / 2.0)
        (text as NSString).draw(at: NSPoint(x: 0, y: drawY), withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
