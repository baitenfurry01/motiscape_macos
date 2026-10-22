/// User intent survives automatic hiding for management pages or narrow layouts.
struct InspectorPresentationState {
    private(set) var isRequested = true
    private(set) var isAutomaticallyHidden = false

    func isPresented(supportsInspector: Bool) -> Bool {
        supportsInspector && isRequested && !isAutomaticallyHidden
    }

    mutating func setAutomaticallyHidden(_ hidden: Bool) {
        isAutomaticallyHidden = hidden
    }

    mutating func receiveSystemPresentation(_ presented: Bool, supportsInspector: Bool) {
        // SwiftUI can echo false when a section/layout hides the inspector.
        // That is not a user dismissal and must not overwrite their preference.
        guard supportsInspector, !isAutomaticallyHidden else { return }
        isRequested = presented
    }

    mutating func show(supportsInspector: Bool) {
        guard supportsInspector else { return }
        isRequested = true
        isAutomaticallyHidden = false
    }

    mutating func toggle(supportsInspector: Bool) {
        guard supportsInspector else { return }
        let wasPresented = isPresented(supportsInspector: supportsInspector)
        isRequested = !wasPresented
        isAutomaticallyHidden = false
    }
}
