#if DEBUG
import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Only the marked, sandboxed integration bundle and explicitly selected source
/// can use this one-shot loader. Release has no alternate media source path.
enum AppFrameCancellationFixture {
    private static let lock = NSLock()
    private static var used = false
    private static func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
    static func probeIfRequested(_ url: URL) async throws -> ImportVideoInfo? {
        guard let source = AppIntegrationFixture.frameCancellationSource,
              url.resolvingSymlinksInPath().standardizedFileURL == source, claim() else { return nil }
        let bytes = try Data(contentsOf: source)
        guard bytes.count > 8 * 1024 * 1024, bytes.count < 10 * 1024 * 1024 else { throw ImportMetadataError.video }
        let loader = Loader(bytes: bytes)
        defer {
            // Observe real termination/deallocation after this frame unwinds.
            // Never complete a request here to manufacture a passing trace.
            Task.detached {
                for _ in 0..<200 {
                    if loader.released {
                        AppIntegrationFixture.record("frame-ui-resources-released")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                AppIntegrationFixture.record("frame-ui-resource-leak", fields: loader.diagnostics)
            }
        }
        let asset = AVURLAsset(url: URL(string: "motiscape-frame-ui://fixture/source.mp4")!)
        loader.observe(asset)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        do {
            // Extended only for deliberate human/UI interaction with this explicit
            // fixture. The production default remains 30 s; service tests verify
            // its ordinary timeout path independently.
            let info = try await ImportMediaPreflight.video(asset: asset, timeoutSeconds: 120,
                                                          willGenerateFirstFrame: { loader.arm() })
            AppIntegrationFixture.record("frame-ui-unexpected-success")
            return info
        } catch {
            AppIntegrationFixture.record("frame-ui-ended", fields: ["cancelled": String(Task.isCancelled),
                "cancellationError": String(error is CancellationError), "error": String(describing: error)])
            throw error
        }
    }

    private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "motiscape.fixture.ui-frame", autoreleaseFrequency: .workItem)
        private let bytes: Data
        private let lock = NSLock()
        private var armed = false
        private var metadataEnd = 0
        private var pending: [AVAssetResourceLoadingRequest] = []
        private weak var asset: AVURLAsset?
        private final class WeakRequest {
            weak var value: AVAssetResourceLoadingRequest?
            init(_ request: AVAssetResourceLoadingRequest) { value = request }
        }
        private var requests: [WeakRequest] = []
        init(bytes: Data) { self.bytes = bytes }
        func observe(_ value: AVURLAsset) { lock.lock(); defer { lock.unlock() }; asset = value }
        func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
        var released: Bool {
            lock.lock(); defer { lock.unlock() }
            pending.removeAll { $0.isCancelled || $0.isFinished }
            return pending.isEmpty && asset == nil && requests.allSatisfy { $0.value == nil }
        }
        var diagnostics: [String: String] {
            lock.lock(); defer { lock.unlock() }
            return ["assetAlive": String(asset != nil), "pending": String(pending.count),
                "retained": String(requests.filter { $0.value != nil }.count),
                "requestStates": pending.map { "cancelled=\($0.isCancelled),finished=\($0.isFinished)" }.joined(separator: ";")]
        }
        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            lock.lock()
            requests.append(WeakRequest(request))
            let frame = armed && request.dataRequest != nil
            if frame { pending.append(request) }
            let deliveredMetadataEnd = metadataEnd
            lock.unlock()
            if let info = request.contentInformationRequest {
                info.contentType = UTType.mpeg4Movie.identifier
                info.contentLength = Int64(bytes.count)
                info.isByteRangeAccessSupported = true
            }
            if let read = request.dataRequest {
                let start = Int(read.currentOffset)
                let end = read.requestsAllDataToEndOfResource ? bytes.count : min(bytes.count, Int(read.requestedOffset) + read.requestedLength)
                guard start >= 0, start <= end else {
                    request.finishLoading(with: NSError(domain: "FrameUIFixture", code: 1)); return true
                }
                if frame {
                    AppIntegrationFixture.record("frame-ui-held", fields: ["offset": String(start),
                        "end": String(end), "metadataEnd": String(deliveredMetadataEnd)])
                    return true
                }
                let deliveredEnd = min(end, start + 64 * 1024)
                read.respond(with: bytes.subdata(in: start..<deliveredEnd))
                lock.lock()
                metadataEnd = max(metadataEnd, deliveredEnd)
                if deliveredEnd < end { pending.append(request) }
                lock.unlock()
                if deliveredEnd < end { return true }
            }
            request.finishLoading(); return true
        }
        func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
            lock.lock(); defer { lock.unlock() }
            pending.removeAll { $0 === request }
        }
    }
}
#endif
