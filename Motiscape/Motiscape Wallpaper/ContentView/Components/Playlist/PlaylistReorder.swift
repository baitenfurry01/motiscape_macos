import SwiftUI
import UniformTypeIdentifiers

struct PlaylistInsertion: Equatable {
    let targetID: String
    let after: Bool

    static func horizontal(at x: CGFloat, itemExtent: CGFloat, ids: [String], sourceID: String) -> Self? {
        guard !ids.isEmpty, itemExtent > 0, x.isFinite else { return nil }
        let boundedX = min(max(0, x), CGFloat(ids.count) * itemExtent)
        // One canonical slot for both sides of a card gap, including either end.
        let slot = min(Int((boundedX / itemExtent + 0.5).rounded(.down)), ids.count)
        let candidate = slot == ids.count
            ? Self(targetID: ids[ids.count - 1], after: true)
            : Self(targetID: ids[slot], after: false)
        return candidate.destination(in: ids, sourceID: sourceID) == nil ? nil : candidate
    }

    func destination(in ids: [String], sourceID: String) -> Int? {
        guard let source = ids.firstIndex(of: sourceID),
              let target = ids.firstIndex(of: targetID) else { return nil }
        let destination = target + (after ? 1 : 0)
        return destination == source || destination == source + 1 ? nil : destination
    }
}

struct PlaylistDragState {
    static let contentType = UTType.text
    let sourceID: String
    let token = UUID().uuidString
    var insertion: PlaylistInsertion?

    func provider() -> NSItemProvider {
        return NSItemProvider(object: token as NSString)
    }
}

/// Highlights an insertion slot while dragging; commits once on mouse release.
/// A per-drag token rejects stale, foreign and cross-list drops.
struct PlaylistReorderDropDelegate: DropDelegate {
    let targetID: String
    let ids: [String]
    let axis: Axis
    let extent: CGFloat
    @Binding var drag: PlaylistDragState?
    let onMove: (String, PlaylistInsertion) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let drag else { return false }
        return ids.contains(drag.sourceID) && info.hasItemsConforming(to: [PlaylistDragState.contentType])
    }

    private func insertion(at location: CGPoint) -> PlaylistInsertion? {
        guard let drag else { return nil }
        let coordinate = axis == .horizontal ? location.x : location.y
        let candidate = PlaylistInsertion(targetID: targetID, after: coordinate >= extent / 2)
        return candidate.destination(in: ids, sourceID: drag.sourceID) == nil ? nil : candidate
    }

    func dropEntered(info: DropInfo) {
        drag?.insertion = insertion(at: info.location)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        drag?.insertion = insertion(at: info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if drag?.insertion?.targetID == targetID { drag?.insertion = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let source = drag,
              let insertion = insertion(at: info.location),
              let provider = info.itemProviders(for: [PlaylistDragState.contentType]).first else {
            drag = nil
            return false
        }
        drag = nil
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let token = value as? String, token == source.token else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.22)) { onMove(source.sourceID, insertion) }
            }
        }
        return true
    }
}

struct PlaylistInsertionLine: View {
    let axis: Axis
    var thickness: CGFloat = 3
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: axis == .horizontal ? thickness : nil, height: axis == .vertical ? thickness : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
