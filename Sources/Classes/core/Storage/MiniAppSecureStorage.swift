import Foundation
import CryptoKit

protocol MiniAppSecureStorageDelegate: AnyObject {
    /// retrieve a value from the storage
    func get(key: String) throws -> String?

    /// add a key/value set and save it to the disk
    func set(dict: [String: String], completion: ((Result<Bool, MiniAppSecureStorageError>) -> Void)?)

    /// remove a set of keys from the storage and save it to disk
    func remove(keys: [String], completion: ((Result<Bool, MiniAppSecureStorageError>) -> Void)?)

    /// retrieve the storage size in bytes
    func size() -> MiniAppSecureStorageSize

    /// clears the current storage
    func clearSecureStorage() throws
}

public class MiniAppSecureStorage: MiniAppSecureStorageDelegate {

    let appId: String

    /// file size defined in bytes
    var fileSizeLimit: UInt64

    private var storage: [String: String]?
    private var isStoreLoading: Bool = false
    var isBusy: Bool = false

    private static let storageName: String = "securestorage"
    static var storageFullName: String { return storageName + ".plist" }

    public init(appId: String, storageMaxSizeInBytes: UInt64? = nil) {
        self.appId = appId
        self.fileSizeLimit = storageMaxSizeInBytes ?? 2_000_000
        do {
            try setup(appId: appId)
        } catch {
            MiniAppLogger.d("🔑 Secure Storage: ❌❌❌ critical error setup did not complete")
        }
    }

    deinit {
        MiniAppLogger.d("🔑 Secure Storage: deinit")
    }

    private func setup(appId: String) throws {
        let secureStoragePath = MiniAppSecureStorage.storagePath(appId: appId)
        MiniAppLogger.d("🔑 Secure Storage: \(secureStoragePath)")
        guard
            !FileManager.default.fileExists(atPath: secureStoragePath.path)
        else {
            MiniAppLogger.d("🔑 Secure Storage: store exists")
            return
        }
        MiniAppLogger.d("🔑 Secure Storage: store does not exist")
        MiniAppLogger.d("🔑 Secure Storage: write to disk")
        let secureStorage: [String: String] = [:]
        let secureStorageData = try PropertyListEncoder().encode(secureStorage)
        try secureStorageData.write(to: secureStoragePath, options: .completeFileProtectionUnlessOpen)
    }

    // MARK: - Load/Unload
    public func loadStorage(completion: ((Bool) -> Void)? = nil) {
        isStoreLoading = true
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let strongSelf = self else { return }
            let loadedStorage = FileManager.default.retrievePlist(
                MiniAppSecureStorage.storageFullName,
                from: MiniAppSecureStorage.miniAppPath(appId: strongSelf.appId),
                as: [String: String].self
            )
            DispatchQueue.main.async {
                strongSelf.isStoreLoading = false
                strongSelf.storage = loadedStorage
                completion?(loadedStorage != nil)
            }
        }
    }

    func unloadStorage() {
        self.storage = nil
    }

    // MARK: - Actions
    func get(key: String) throws -> String? {
        guard let storage = storage else { throw MiniAppSecureStorageError.storageUnvailable }
        MiniAppLogger.d("🔑 Secure Storage: get '\(key)'")
        return storage[key]
    }

    func set(dict: [String: String], completion: ((Result<Bool, MiniAppSecureStorageError>) -> Void)? = nil) {
        guard let memorySize = try? getMemoryStorageFileSize() else {
            completion?(.failure(.storageUnvailable))
            return
        }
        guard storage != nil else {
            completion?(.failure(.storageUnvailable))
            return
        }
        guard !isBusy else {
            completion?(.failure(.storageBusy))
            return
        }

        do {
            try validateAvailableSpace(for: dict)
            MiniAppLogger.d("🔑 Secure Storage: sufficient space for insert available")
        } catch let error {
            let storageError = error as? MiniAppSecureStorageError
            completion?(.failure(storageError ?? .storageIOError))
            return
        }

        isBusy = true
        for (key, value) in dict {
            MiniAppLogger.d("🔑 Secure Storage: set '\(key)'")
            storage?[key] = value
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let strongSelf = self else { return }
            do {
                try strongSelf.saveStoreToDisk()
                DispatchQueue.main.async {
                    strongSelf.isBusy = false
                    completion?(.success(true))
                    MiniAppLogger.d("🔑 Secure Storage: set finish")
                }
            } catch let error {
                strongSelf.isBusy = false
                if let error = error as? MiniAppSecureStorageError {
                    completion?(.failure(error))
                } else {
                    completion?(.failure(.storageIOError))
                }
                return
            }
        }
    }

    func remove(keys: [String], completion: ((Result<Bool, MiniAppSecureStorageError>) -> Void)? = nil) {
        guard storage != nil else {
            completion?(.failure(MiniAppSecureStorageError.storageUnvailable))
            return
        }
        guard !isBusy else {
            completion?(.failure(MiniAppSecureStorageError.storageBusy))
            return
        }
        isBusy = true
        for key in keys {
            MiniAppLogger.d("🔑 Secure Storage: remove '\(key)'")
            storage?.removeValue(forKey: key)
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let strongSelf = self else { return }
            do {
                try strongSelf.saveStoreToDisk()
                DispatchQueue.main.async {
                    strongSelf.isBusy = false
                    completion?(.success(true))
                }
            } catch let error {
                strongSelf.isBusy = false
                if let error = error as? MiniAppSecureStorageError {
                    completion?(.failure(error))
                } else {
                    completion?(.failure(.storageIOError))
                }
                return
            }
        }
    }

    // MARK: - Internal
    private func loadLocalStorage() -> [String: String]? {
        let secureStoragePath = MiniAppSecureStorage.miniAppPath(appId: appId)
        let secureStorageName = MiniAppSecureStorage.storageName + ".plist"
        let loadedStorage = FileManager.default.retrievePlist(secureStorageName, from: secureStoragePath, as: [String: String].self)
        return loadedStorage
    }

    private static func miniAppPath(appId: String) -> URL {
        return FileManager.getMiniAppDirectory(with: appId)
    }

    private static func storagePath(appId: String) -> URL {
        return FileManager.getMiniAppDirectory(with: appId).appendingPathComponent("/\(storageName).plist")
    }

    private func saveStoreToDisk(completion: (() -> Void)? = nil) throws {
        guard let storage = storage else { throw MiniAppSecureStorageError.storageUnvailable }
        MiniAppLogger.d("🔑 Secure Storage: write store to disk")
        let secureStoragePath = MiniAppSecureStorage.storagePath(appId: appId)
        let secureStorageData = try PropertyListEncoder().encode(storage)
        try secureStorageData.write(to: secureStoragePath, options: .completeFileProtectionUnlessOpen)
        MiniAppLogger.d("🔑 Secure Storage: write store to disk completed")
    }

    // MARK: - Clear All Secure Storage
    internal static func wipeSecureStorages() {
        MiniAppLogger.d("🔑 Secure Storage: destroy")
        guard let contentNames = try? FileManager.default.contentsOfDirectory(atPath: FileManager.getMiniAppFolderPath().path) else { return }
        for name in contentNames {
            let url = FileManager.getMiniAppFolderPath().appendingPathComponent("/" + name)
            do {
                if let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory, isDirectory {
                    do {
                        try FileManager.default.removeItem(at: url.appendingPathComponent("/" + MiniAppSecureStorage.storageFullName))
                        MiniAppLogger.d("🔑 Secure Storage: destroyed storaged for \(name)")
                    } catch {
                        MiniAppLogger.d("🔑 Secure Storage: could not destroy storaged for \(name)")
                    }
                } else {
                    MiniAppLogger.d("🔑 Secure Storage: ignored \(name)")
                }
            } catch let error {
                MiniAppLogger.d("🔑 Secure Storage Wipe Failed: \(name)", error.localizedDescription)
            }
        }
    }

    // MARK: - Clear storage for MiniApp ID
    internal static func wipeSecureStorage(for miniAppId: String) {
        if !miniAppId.isEmpty {
            MiniAppLogger.d("🔑 Secure Storage for MiniApp ID: destroy")
            let miniAppPath = FileManager.getMiniAppFolderPath().appendingPathComponent(miniAppId)
            do {
                try FileManager.default.removeItem(at: miniAppPath.appendingPathComponent("/" + MiniAppSecureStorage.storageFullName))
                MiniAppLogger.d("🔑 Secure Storage for MiniApp ID: destroyed storaged for \(miniAppId)")
            } catch {
                MiniAppLogger.d("🔑 Secure Storage for MiniApp ID: could not destroy storaged for \(miniAppId)")
            }
        }
    }

    func clearSecureStorage() throws {
        MiniAppLogger.d("🔑 Secure Storage: destroy")
        self.storage?.removeAll()
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let strongSelf = self else { return }
            do {
                try strongSelf.saveStoreToDisk()
            } catch let error {
                strongSelf.isBusy = false
                MiniAppLogger.d("🔑 Secure Storage clear error: ", error.localizedDescription)
                return
            }
            DispatchQueue.main.async {
                strongSelf.isBusy = false
                MiniAppLogger.d("🔑 Secure Storage: clear storage finish")
            }
        }
    }

    // MARK: - Size
    func getMemoryStorageFileSize() throws -> UInt64 {
        guard
            let strg = storage,
            let storageSize = try? PropertyListEncoder().encode(strg)
        else {
            throw MiniAppSecureStorageError.storageUnvailable
        }
        let size = storageSize.count
        MiniAppLogger.d("🔑 Secure Storage: memory size -> \(size)")
        return UInt64(size)
    }

    func validateAvailableSpace(key: String, value: String) throws {
        let estimateAddString = "<key>" + key + "</key><string>" + value + "</string>"
        guard
            let estimateAddData = estimateAddString.data(using: .utf8),
            let memorySize = try? getMemoryStorageFileSize()
        else {
            throw MiniAppSecureStorageError.storageIOError
        }
        let estimatedAddSize = UInt64(estimateAddData.count)
        let estimatedFinalSize = memorySize + estimatedAddSize
        guard estimatedFinalSize <= fileSizeLimit else {
            throw MiniAppSecureStorageError.storageFullError
        }
    }

    func validateAvailableSpace(for dict: [String: String]) throws {
        guard
            let dictData = try? PropertyListEncoder().encode(dict),
            let memorySize = try? getMemoryStorageFileSize()
        else {
            throw MiniAppSecureStorageError.storageIOError
        }
        let estimatedAddSize = UInt64(dictData.count)
        let estimatedFinalSize = memorySize + estimatedAddSize
        guard estimatedFinalSize <= fileSizeLimit else {
            throw MiniAppSecureStorageError.storageFullError
        }
    }

    var storageFileSize: UInt64 {
        let fileSize = MiniAppSecureStorage.storagePath(appId: appId).fileSize
        MiniAppLogger.d("🔑 Secure Storage: size -> \(fileSize)")
        return fileSize
    }

    func size() -> MiniAppSecureStorageSize {
        return MiniAppSecureStorageSize(used: storageFileSize, max: fileSizeLimit)
    }

    func storageSize(for miniAppId: String) -> UInt64 {
        let fileSize = MiniAppSecureStorage.storagePath(appId: miniAppId).fileSize
        MiniAppLogger.d("🔑 Secure Storage: size -> \(fileSize)")
        return fileSize
    }

    // MARK: - Notifications
    static func sendLoadStorageReady() {
        NotificationCenter.default.sendCustomEvent(MiniAppEvent.Event(type: .secureStorageReady,
                                                                      comment: "MiniApp Secure Storage Ready"))
    }

    static func sendLoadStorageError() {
        NotificationCenter.default.sendCustomEvent(MiniAppEvent.Event(type: .secureStorageError,
                                                                      comment: "MiniApp Secure Storage Error"))
    }
}

struct MiniAppSecureStorageSize: Codable {
    let used: UInt64
    let max: UInt64
}

public enum MiniAppSecureStorageError: Error, MiniAppErrorProtocol, Equatable {

    case storageFullError
    case storageIOError
    case storageUnvailable
    case storageBusy

    var name: String {
        switch self {
        case .storageFullError:
            return "SecureStorageFullError"
        case .storageIOError:
            return "SecureStorageIOError"
        case .storageUnvailable:
            return "SecureStorageUnavailableError"
        case .storageBusy:
            return "SecureStorageBusyError"
        }
    }

    var description: String {
        switch self {
        case .storageFullError:
            return "Storage size exceeded"
        case .storageIOError:
            return "IO or unknown error occured"
        case .storageUnvailable:
            return "StorageUnavailable"
        case .storageBusy:
            return "UnavailableItem"
        }
    }
}