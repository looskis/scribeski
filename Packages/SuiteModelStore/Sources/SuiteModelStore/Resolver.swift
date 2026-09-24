import Darwin
import Foundation

/// The outcome of choosing a model for one role. The resolver never silently substitutes a
/// different model: if the chosen one doesn't fit, it says so and the app decides.
public struct Resolution: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        case userChoice = "user_choice"
        case catalogDefault = "catalog_default"
    }

    public enum Status: String, Sendable, Hashable {
        case ok
        /// The machine has less RAM than the model's `min_ram_gb`.
        case insufficientRAM = "insufficient_ram"
        /// The selection names a catalog id the catalog doesn't contain (e.g. removed in an update).
        case unknownModel = "unknown_model"
        /// The selection names a catalog model for a different role.
        case roleMismatch = "role_mismatch"
        /// No user choice and the catalog has no default for this role.
        case noDefault = "no_default"
    }

    public enum Model: Sendable, Hashable {
        case catalog(ModelManifest)
        case custom(CustomModel)
    }

    public var role: ModelRole
    public var origin: Origin
    public var status: Status
    public var model: Model?
    /// False for custom models and for catalog entries that haven't passed the eval gates.
    public var validated: Bool
    public var requiredRAMGB: Int?
    public var availableRAMGB: Double

    public var isCustom: Bool { if case .custom = model { true } else { false } }

    /// The manifest to `ensure`: the catalog entry, or a remote custom model's synthesized manifest.
    public var manifest: ModelManifest? {
        switch model {
        case let .catalog(m): return m
        case let .custom(c): return c.manifest(role: role)
        case nil: return nil
        }
    }
}

public enum Resolver {
    /// User choice if set, else the catalog default for `role`; then a RAM check against
    /// `ram` (bytes; defaults to this machine's `hw.memsize`).
    public static func resolve(
        role: ModelRole, selection: ModelSelection, catalog: Catalog,
        ram: UInt64 = SystemInfo.physicalMemory
    ) -> Resolution {
        let ramGB = Double(ram) / Double(1 << 30)
        func result(_ origin: Resolution.Origin, _ status: Resolution.Status, _ model: Resolution.Model?,
                    validated: Bool, required: Int?) -> Resolution {
            Resolution(role: role, origin: origin, status: status, model: model, validated: validated,
                       requiredRAMGB: required, availableRAMGB: ramGB)
        }
        func ramStatus(_ required: Int?) -> Resolution.Status {
            guard let required, required > 0 else { return .ok }
            return ramGB + 0.01 < Double(required) ? .insufficientRAM : .ok
        }

        switch selection[role] {
        case let .catalog(id)?:
            guard let m = catalog.model(id: id) else {
                return result(.userChoice, .unknownModel, nil, validated: false, required: nil)
            }
            guard m.role == role else {
                return result(.userChoice, .roleMismatch, .catalog(m), validated: m.validated, required: m.minRAMGB)
            }
            return result(.userChoice, ramStatus(m.minRAMGB), .catalog(m), validated: m.validated, required: m.minRAMGB)
        case let .custom(c)?:
            return result(.userChoice, ramStatus(c.minRAMGB), .custom(c), validated: false, required: c.minRAMGB)
        case nil:
            guard let m = catalog.defaultModel(for: role) else {
                return result(.catalogDefault, .noDefault, nil, validated: false, required: nil)
            }
            return result(.catalogDefault, ramStatus(m.minRAMGB), .catalog(m), validated: m.validated, required: m.minRAMGB)
        }
    }
}

public enum SystemInfo {
    /// Physical memory in bytes (`sysctl hw.memsize`).
    public static var physicalMemory: UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 { return size }
        return ProcessInfo.processInfo.physicalMemory
    }
}
