import SwiftUI
import UIKit

/// Measures the tab bar against a tab's content area, so screens can stop their last card just above it
/// instead of guessing a fixed gap. Reports nothing when no tab bar can be found (callers keep the old gap).
struct TabBarProbe: UIViewRepresentable {
    struct Reading: Equatable {
        /// How far the bar reaches over the content's bottom edge. 0 when iOS already keeps content clear.
        var overlap: CGFloat
        /// How far the bar's top sits above the window's safe-area bottom (the home indicator line).
        var rise: CGFloat
    }

    let onMeasure: (Reading) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onMeasure = onMeasure
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onMeasure = onMeasure
    }

    final class ProbeView: UIView {
        var onMeasure: ((Reading) -> Void)?
        private var last: Reading?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        private func measure() {
            guard let window, let bar = tabBar(), !bar.isHidden, bar.alpha > 0.01, bar.window != nil else { return }
            let barTop = bar.convert(bar.bounds, to: window).minY
            // A bar not laid out yet reads at the top of the screen; wait for a real position.
            guard barTop > window.bounds.height * 0.6, bar.bounds.height > 0 else { return }
            // Content stops at this view's bottom less whatever safe area it still carries.
            let contentBottom = convert(bounds, to: window).maxY - safeAreaInsets.bottom
            let reading = Reading(
                overlap: min(200, max(0, (contentBottom - barTop).rounded())),
                rise: min(200, max(0, (window.bounds.maxY - window.safeAreaInsets.bottom - barTop).rounded())))
            guard reading != last else { return }
            last = reading
            let report = onMeasure
            DispatchQueue.main.async { report?(reading) }
        }

        private func tabBar() -> UITabBar? {
            var r: UIResponder? = self
            while let next = r?.next {
                if let vc = next as? UIViewController, let tbc = vc.tabBarController { return tbc.tabBar }
                r = next
            }
            return Self.find(in: window?.rootViewController)?.tabBar
        }

        private static func find(in vc: UIViewController?) -> UITabBarController? {
            guard let vc else { return nil }
            if let tbc = vc as? UITabBarController { return tbc }
            for child in vc.children { if let t = find(in: child) { return t } }
            return find(in: vc.presentedViewController)
        }
    }
}
