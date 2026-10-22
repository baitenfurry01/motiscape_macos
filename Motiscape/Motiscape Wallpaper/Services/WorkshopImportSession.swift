import Foundation
import Observation

enum WorkshopImportError: LocalizedError {
    case invalidReference, unavailableItem, wrongApplication, queueUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidReference: return L("请输入有效的工坊 ID 或 steamcommunity.com 作品链接。")
        case .unavailableItem: return L("未找到可下载的作品，可能已删除、设为私有或不是单个壁纸。")
        case .wrongApplication: return L("该作品不属于 Wallpaper Engine，无法导入。")
        case .queueUnavailable: return L("下载队列尚未就绪，请在下载页检查存储状态后重试。")
        }
    }
}

/// Only extracts an ID. Never requests a pasted URL, opens Steam, or treats it
/// as a filesystem path. Canonical IDs prevent leading-zero duplicate jobs.
enum WorkshopImportReference {
    static func parse(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = canonicalID(text) { return id }
        guard text.utf8.count <= 4096,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URLComponents(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["steamcommunity.com", "www.steamcommunity.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              ["/sharedfiles/filedetails", "/sharedfiles/filedetails/",
               "/workshop/filedetails", "/workshop/filedetails/"].contains(url.percentEncodedPath)
        else { throw WorkshopImportError.invalidReference }
        let ids = (url.queryItems ?? []).filter { $0.name == "id" }
        guard ids.count == 1, let raw = ids[0].value, let id = canonicalID(raw) else {
            throw WorkshopImportError.invalidReference
        }
        return id
    }

    private static func canonicalID(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 20,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(text), number > 0 else { return nil }
        return String(number)
    }
}

@MainActor protocol WorkshopImportResolving {
    func resolveImport(id: String) async throws -> WorkshopItem
}

extension SteamWebAPI: WorkshopImportResolving {
    func resolveImport(id: String) async throws -> WorkshopItem {
        let items = try await getFileDetails(workshopIds: [id], enrichCreatorProfiles: false)
        guard let item = items.first(where: { $0.id == id }), item.fileSize > 0,
              item.workshopFileType == nil || item.workshopFileType == 0 else {
            throw WorkshopImportError.unavailableItem
        }
        guard item.consumerAppId == 431960 else { throw WorkshopImportError.wrongApplication }
        return item
    }
}

enum WorkshopImportReceipt { case queued, existing, installed }

/// An edit invalidates the preview immediately, including services that ignore
/// Task cancellation. Confirmation is explicit and cannot use an older input.
@MainActor @Observable final class WorkshopImportSession {
    var input = "" { didSet { if oldValue != input { invalidate() } } }
    private(set) var item: WorkshopItem?
    private(set) var error: String?
    private(set) var isResolving = false
    private(set) var isSubmitting = false
    private(set) var receipt: WorkshopImportReceipt?
    private let resolver: any WorkshopImportResolving
    private var revision = 0
    private var operation: Task<Void, Never>?

    init(resolver: any WorkshopImportResolving = SteamWebAPI.shared) { self.resolver = resolver }

    func invalidate() {
        revision += 1
        operation?.cancel(); operation = nil
        item = nil; error = nil; receipt = nil; isResolving = false
    }

    func resolve() {
        guard !isSubmitting else { return }
        invalidate()
        let id: String
        do { id = try WorkshopImportReference.parse(input) }
        catch { self.error = error.localizedDescription; return }
        let current = revision
        isResolving = true
        operation = Task { @MainActor [weak self, resolver] in
            do {
                let item = try await resolver.resolveImport(id: id)
                guard let self, self.revision == current, !Task.isCancelled else { return }
                // Also validate injectable/future providers at the presentation boundary.
                guard item.id == id, item.fileSize > 0, item.kind != .unsupported,
                      item.workshopFileType == nil || item.workshopFileType == 0 else {
                    throw WorkshopImportError.unavailableItem
                }
                guard item.consumerAppId == 431960 else { throw WorkshopImportError.wrongApplication }
                self.item = item; self.isResolving = false; self.operation = nil
            } catch {
                guard let self, self.revision == current, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isResolving = false; self.operation = nil
            }
        }
    }

    func confirm(enqueue: @escaping @MainActor (WorkshopItem) async throws -> WorkshopImportReceipt) {
        guard !isResolving, !isSubmitting, receipt == nil, let item else { return }
        error = nil; isSubmitting = true
        let current = revision
        // Once confirmed, dismissal/input changes must not cancel a durable
        // queue command. This task is deliberately separate from lookup.
        Task { @MainActor [weak self] in
            do {
                let receipt = try await enqueue(item)
                if self?.revision == current { self?.receipt = receipt }
            } catch {
                if self?.revision == current { self?.error = error.localizedDescription }
            }
            self?.isSubmitting = false
        }
    }
}
