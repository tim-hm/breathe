import BreatheKit
import BreatheUI
import SwiftUI
import UIKit

/// The intent wheel's UIKit heart.
///
/// A `UIViewRepresentable` rather than SwiftUI's `.wheel` picker for one
/// reason: the selection pill is drawn at the picker's row height, and the
/// SwiftUI wheel neither exposes row height nor grows it past the label's
/// intrinsic size. This wrapper exists so `rowHeightForComponent` can make
/// the pill a generous target instead of a snug ring around the text.
struct GoalWheel: UIViewRepresentable {
    let goals: [TechniqueGoal]
    @Binding var selection: TechniqueGoal

    /// Row — and therefore pill — height.
    static let rowHeight: CGFloat = 64

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.goals != goals {
            coordinator.goals = goals
            picker.reloadAllComponents()
        }

        // Written back without animation: this is state restoration and the
        // guard against a selection the catalogue no longer serves, not a spin.
        if let row = goals.firstIndex(of: selection),
           picker.selectedRow(inComponent: 0) != row
        {
            picker.selectRow(row, inComponent: 0, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Without this, the picker answers with its own preferred width (~320pt)
    /// and draws its selection pill right across the neighbouring label —
    /// `UIPickerView` does not treat a narrower frame as binding unless the
    /// representable adopts the proposal explicitly.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: UIPickerView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: GoalWheel
        var goals: [TechniqueGoal]

        init(_ parent: GoalWheel) {
            self.parent = parent
            goals = parent.goals
        }

        func numberOfComponents(in _: UIPickerView) -> Int {
            1
        }

        func pickerView(_: UIPickerView, numberOfRowsInComponent _: Int) -> Int {
            goals.count
        }

        func pickerView(_: UIPickerView, rowHeightForComponent _: Int) -> CGFloat {
            GoalWheel.rowHeight
        }

        func pickerView(
            _: UIPickerView,
            viewForRow row: Int,
            forComponent _: Int,
            reusing view: UIView?
        ) -> UIView {
            let label = view as? UILabel ?? UILabel()
            label.text = goals.indices.contains(row) ? goals[row].intentObject : ""
            label.textAlignment = .center
            label.font = UIFontMetrics(forTextStyle: .title2)
                .scaledFont(for: .systemFont(ofSize: 22, weight: .semibold))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(Theme.Ink.primary)
            return label
        }

        func pickerView(_: UIPickerView, didSelectRow row: Int, inComponent _: Int) {
            guard goals.indices.contains(row) else { return }
            parent.selection = goals[row]
        }
    }
}
