import Combine
import SwiftUI
import UIKit

/*
 Rolling counter, adapted from Bencho's MIT-licensed Rolling Counter.

 Each column counts its whole place value, it does not just show a
 digit: 1284 is 1284 in the ones column, 128 in the tens, and 12 in
 the hundreds. This makes a carry (9 → 10) continue forward through
 the second zero on the strip instead of sending a wheel backwards.

 Every place owns a spring. The ones column is due first; each column
 to its left waits Stagger milliseconds, so a carry ripples across.

 The simulation uses display frames, not milliseconds. `dt` is in
 sixtieths of a second and damping is raised to `dt`; multiplying the
 damping would make a spring behave differently after a dropped frame.
 The display link is invalidated as soon as every spring has settled.

 Bounce maps 0…100 to stiffness and decay. The chosen pair is judged
 by damping ratio, zeta = -ln(d) / (2 * sqrt(k)), rather than by either
 number alone: 0 gives about 0.85, 50 about 0.41, and 100 about 0.20.
 That makes the slow end arrive without ringing and lets the fast end
 show a small rebound. The earlier 0.06…0.26 / 0.93…0.74 pairing kept
 zeta almost fixed around 0.15, so every setting overshot by about 60%.

 Button holds start with single steps, speed up after 900 ms, and move
 by tens after 1.5 seconds. Dragging uses 12-point steps; release gives
 the last motion a short, damped coast. Reduce Motion skips the springs
 and fling while keeping all three ways to change the value.

 The CSS tokens are mapped locally: card/slab to the grouped surface,
 ink/fill to the semantic foreground, pane-edge to the system separator,
 signal/focus to the system accessibility focus treatment, and UI font
 to rounded system digits. SF Symbols replace lucide-react; there are no
 global color or font definitions to leak into the app.
*/

@MainActor
struct RollingCounter: View {
    @Binding private var value: Int
    @StateObject private var motion: RollingCounterMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var dragLastTime: CFTimeInterval = 0
    @State private var isDragging = false
    @State private var activeButton: Int?

    private let bounce: Double
    private let stagger: Double
    private let blur: Double
    private let corner: CGFloat

    init(
        value: Binding<Int>,
        bounce: Double = 45,
        stagger: Double = 45,
        blur: Double = 50,
        corner: CGFloat = 16
    ) {
        self._value = value
        self.bounce = min(100, max(0, bounce))
        self.stagger = min(120, max(0, stagger))
        self.blur = min(100, max(0, blur))
        self.corner = min(28, max(0, corner))
        self._motion = StateObject(wrappedValue: RollingCounterMotion(
            start: value.wrappedValue,
            bounce: min(100, max(0, bounce)),
            stagger: min(120, max(0, stagger)),
            blur: min(100, max(0, blur))
        ))
    }

    private var shownPlaces: Int {
        max(1, String(motion.value).count)
    }

    var body: some View {
        HStack(spacing: 0) {
            button(direction: -1, symbol: "minus", label: "减少次数")

            HStack(spacing: 0) {
                ForEach((0..<RollingCounterMotion.places).reversed(), id: \.self) { place in
                    RollingDigitColumn(
                        position: motion.positions[place],
                        blur: motion.blurRadii[place] * blur / 50,
                        isVisible: place < shownPlaces
                    )

                    if place == 3 {
                        Text(",")
                            .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(width: shownPlaces > 3 ? 7.8 : 0, height: 46)
                            .clipped()
                            .opacity(shownPlaces > 3 ? 1 : 0)
                            .animation(.easeInOut(duration: 0.22), value: shownPlaces > 3)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.8),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .contentShape(Rectangle())
            .gesture(digitDrag)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("本组引体向上次数")
            .accessibilityValue("\(motion.value) 次")
            .accessibilityAdjustableAction { adjustment in
                switch adjustment {
                case .increment: motion.bump(1)
                case .decrement: motion.bump(-1)
                @unknown default: break
                }
            }

            button(direction: 1, symbol: "plus", label: "增加次数")
        }
        .padding(5)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: corner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
        }
        .onChange(of: motion.value) { newValue in
            if value != newValue { value = newValue }
        }
        .onChange(of: value) { newValue in
            if motion.value != newValue { motion.setValue(newValue) }
        }
        .onDisappear { motion.stop() }
    }

    private func button(direction: Int, symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(direction < 0 && motion.value == 0 ? Color.secondary : Color.primary)
            .frame(width: 40, height: 46)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: max(0, corner - 5), style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: max(0, corner - 5), style: .continuous))
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) {
                motion.bump(direction)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard activeButton != direction else { return }
                        activeButton = direction
                        motion.beginHolding(direction)
                    }
                    .onEnded { _ in
                        activeButton = nil
                        motion.endHolding()
                    }
            )
            .scaleEffect(activeButton == direction ? 0.9 : 1)
            .animation(.easeOut(duration: activeButton == direction ? 0.11 : 0.2), value: activeButton)
    }

    private var digitDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let now = CACurrentMediaTime()
                if !isDragging {
                    isDragging = true
                    dragTranslation = gesture.translation.height
                    dragLastTime = now
                    motion.beginDrag()
                    return
                }

                let deltaY = dragTranslation - gesture.translation.height
                let elapsed = max(0.001, now - dragLastTime)
                dragTranslation = gesture.translation.height
                dragLastTime = now
                motion.drag(by: Double(deltaY), elapsed: elapsed)
            }
            .onEnded { _ in
                let sinceLastMove = CACurrentMediaTime() - dragLastTime
                motion.endDrag(lastMoveAge: sinceLastMove)
                isDragging = false
            }
    }
}

@MainActor
private struct RollingDigitColumn: View {
    let position: Double
    let blur: Double
    let isVisible: Bool

    // The digit window and the upright keys share one 46-point height.
    private let cell: CGFloat = 46
    // CSS used 0.64em per digit; 30 pt × 0.64 keeps the pill growing only
    // as digits arrive instead of reserving space for all five places.
    private let digitWidth: CGFloat = 19.2

    private var wheelOffset: CGFloat {
        var remainder = position.truncatingRemainder(dividingBy: 10)
        if remainder < 0 { remainder += 10 }
        return -CGFloat(remainder) * cell
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<11, id: \.self) { row in
                Text(String(row % 10))
                    .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: digitWidth, height: cell)
            }
        }
        .frame(width: digitWidth)
        .offset(y: wheelOffset)
        .blur(radius: min(3, max(0, blur)))
        .frame(width: isVisible ? digitWidth : 0, height: cell, alignment: .top)
        .clipped()
        .opacity(isVisible ? 1 : 0)
        .animation(.timingCurve(0.3, 1.2, 0.4, 1, duration: 0.32), value: isVisible)
        .animation(.easeInOut(duration: 0.22), value: isVisible)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class RollingCounterMotion: ObservableObject {
    static let places = 5
    // Five columns keep the displayed count and place-value targets bounded.
    static let maximum = 99_999
    private static let powers = [1, 10, 100, 1_000, 10_000]

    @Published private(set) var value: Int
    @Published private(set) var positions: [Double]
    @Published private(set) var blurRadii = Array(repeating: 0.0, count: RollingCounterMotion.places)

    private struct Column {
        var position: Double
        var velocity: Double = 0
        var target: Double
        var due: [CFTimeInterval] = []
        var next: [Double] = []
    }

    private var columns: [Column]
    private var bounce: Double
    private let stagger: Double
    private var blur: Double
    private let reducedMotion = UIAccessibility.isReduceMotionEnabled
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var previousTimestamp: CFTimeInterval?

    private var holdTask: Task<Void, Never>?
    private var dragAccumulator = 0.0
    private var dragVelocity = 0.0
    private var flingVelocity = 0.0

    init(start: Int, bounce: Double, stagger: Double, blur: Double) {
        let safeStart = min(Self.maximum, max(0, start))
        self.value = safeStart
        self.bounce = bounce
        self.stagger = stagger
        self.blur = blur
        self.columns = (0..<Self.places).map { place in
            let count = Double(safeStart / Self.powers[place])
            return Column(position: count, target: count)
        }
        self.positions = (0..<Self.places).map { Double(safeStart / Self.powers[$0]) }
    }

    func setValue(_ requested: Int) {
        let safeValue = min(Self.maximum, max(0, requested))
        let difference = safeValue - value
        guard difference != 0 else { return }
        bump(difference)
    }

    func bump(_ delta: Int) {
        let sum = value.addingReportingOverflow(delta)
        let nextValue = sum.overflow
            ? (delta > 0 ? Self.maximum : 0)
            : min(Self.maximum, max(0, sum.partialValue))
        guard nextValue != value else { return }

        value = nextValue
        let now = CACurrentMediaTime()
        for place in 0..<Self.places {
            let target = Double(nextValue / Self.powers[place])
            if reducedMotion {
                columns[place].position = target
                columns[place].velocity = 0
                columns[place].target = target
                columns[place].due.removeAll(keepingCapacity: true)
                columns[place].next.removeAll(keepingCapacity: true)
            } else {
                columns[place].due.append(now + Double(place) * stagger / 1_000)
                columns[place].next.append(target)
            }
        }

        if reducedMotion {
            publishColumns()
        } else {
            startDisplayLink()
        }
    }

    func beginHolding(_ direction: Int) {
        guard holdTask == nil else { return }
        bump(direction)
        let startedAt = CACurrentMediaTime()
        holdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                let heldFor = CACurrentMediaTime() - startedAt
                self.bump(direction * (heldFor > 1.5 ? 10 : 1))
                let interval: UInt64 = heldFor > 0.9 ? 55_000_000 : 90_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func endHolding() {
        holdTask?.cancel()
        holdTask = nil
    }

    func beginDrag() {
        flingVelocity = 0
        dragAccumulator = 0
        dragVelocity = 0
    }

    func drag(by deltaY: Double, elapsed: Double) {
        guard !reducedMotion else { return }
        // Keep velocity in points per millisecond, as in the source, so
        // multiplying by 16.67 on release gives points per display frame.
        dragVelocity = dragVelocity * 0.6 + (deltaY / max(1, elapsed * 1_000)) * 0.4
        // Twelve points per step keeps a short finger movement useful while
        // leaving enough travel to fling multiple counts naturally.
        dragAccumulator += deltaY
        let count = trunc(dragAccumulator / 12)
        guard count != 0 else { return }
        bump(Int(count))
        dragAccumulator -= count * 12
    }

    func endDrag(lastMoveAge: Double) {
        guard !reducedMotion, lastMoveAge <= 0.09 else { return }
        flingVelocity = dragVelocity * (1_000 / 60)
        if abs(flingVelocity) < 2 { return }
        startDisplayLink()
    }

    func stop() {
        endHolding()
        flingVelocity = 0
        columns.indices.forEach { index in
            let finalTarget = Double(value / Self.powers[index])
            columns[index].target = finalTarget
            columns[index].position = finalTarget
            columns[index].velocity = 0
            columns[index].due.removeAll(keepingCapacity: false)
            columns[index].next.removeAll(keepingCapacity: false)
        }
        publishColumns()
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        previousTimestamp = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        displayLinkTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func tick(_ timestamp: CFTimeInterval) {
        let dt: Double
        if let previousTimestamp {
            dt = min(2.5, max(0, (timestamp - previousTimestamp) * 60))
        } else {
            dt = 1
        }
        previousTimestamp = timestamp

        let spring = Self.spring(bounce)
        let now = CACurrentMediaTime()
        var busy = false

        for place in columns.indices {
            while let dueTime = columns[place].due.first, dueTime <= now {
                columns[place].due.removeFirst()
                columns[place].target = columns[place].next.removeFirst()
            }
            if !columns[place].due.isEmpty { busy = true }

            let gap = columns[place].target - columns[place].position
            if abs(gap) > 24 {
                // Large throws skip whole turns first. They look the same,
                // but prevent a high place from spinning for a long time.
                let nearTarget = gap > 0 ? 24.0 : -24.0
                columns[place].position += ((gap - nearTarget) / 10).rounded() * 10
            }
            columns[place].velocity += (columns[place].target - columns[place].position) * spring.stiffness * dt
            columns[place].velocity *= pow(spring.decay, dt)
            columns[place].position += columns[place].velocity * dt

            if abs(columns[place].target - columns[place].position) < 0.004,
               abs(columns[place].velocity) < 0.004 {
                // Snap only when both motion and distance are imperceptible.
                columns[place].position = columns[place].target
                columns[place].velocity = 0
            } else {
                busy = true
            }
        }

        if abs(flingVelocity) > 0.4 {
            dragAccumulator += flingVelocity
            let count = trunc(dragAccumulator / 12)
            if count != 0 {
                bump(Int(count))
                dragAccumulator -= count * 12
            }
            flingVelocity *= pow(0.94, dt)
            if abs(flingVelocity) > 0.4 { busy = true }
        } else {
            flingVelocity = 0
        }

        publishColumns()
        if !busy {
            // Park the display link once all columns and any fling have ended.
            displayLink?.invalidate()
            displayLink = nil
            displayLinkTarget = nil
            previousTimestamp = nil
        }
    }

    private func publishColumns() {
        positions = columns.map(\.position)
        blurRadii = columns.map { min(3, abs($0.velocity) * 2.4) * (blur / 50) }
    }

    private static func spring(_ tune: Double) -> (stiffness: Double, decay: Double) {
        // These endpoint values tune the damping ratio as well as the speed.
        // That keeps the low end from never arriving and the high end lively
        // without allowing every setting to overshoot by the same large amount.
        (0.08 + (tune / 100) * 0.16, 0.62 + (tune / 100) * 0.2)
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var owner: RollingCounterMotion?

    init(owner: RollingCounterMotion) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(link.timestamp)
    }
}
