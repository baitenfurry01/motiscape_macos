import Foundation
import UniformTypeIdentifiers

enum FileDropCollector {
    /// NSItemProvider callbacks may arrive concurrently and out of order.
    /// Preserve drag order without sharing an unprotected mutable Array.
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: URL] = [:]
        func insert(_ url: URL, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            values[index] = url.standardizedFileURL
        }
        func snapshot() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            var seen = Set<String>()
            return values.keys.sorted().compactMap { values[$0] }.filter { seen.insert($0.path).inserted }
        }
    }

    static func collect(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let accumulator = Accumulator()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                if let url, url.isFileURL { accumulator.insert(url, at: index) }
            }
        }
        group.notify(queue: .main) { completion(accumulator.snapshot()) }
    }
}
