import Foundation

/// User preferences, persisted in UserDefaults. An empty device UID means "follow the system default".
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: Keys.input) } }
    @Published var outputDeviceUID: String { didSet { defaults.set(outputDeviceUID, forKey: Keys.output) } }
    @Published var passThrough: Bool { didSet { defaults.set(passThrough, forKey: Keys.passThrough) } }
    @Published var transcriptsFolder: URL { didSet { defaults.set(transcriptsFolder.path, forKey: Keys.folder) } }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Yapr", isDirectory: true)
    }

    private enum Keys {
        static let input = "inputDeviceUID", output = "outputDeviceUID", passThrough = "passThrough", folder = "transcriptsFolder"
    }

    private init() {
        inputDeviceUID = defaults.string(forKey: Keys.input) ?? ""
        outputDeviceUID = defaults.string(forKey: Keys.output) ?? ""
        passThrough = defaults.bool(forKey: Keys.passThrough)
        if let path = defaults.string(forKey: Keys.folder), !path.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            transcriptsFolder = Settings.defaultFolder
        }
    }
}
