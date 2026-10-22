import Foundation

/// User preferences, persisted in UserDefaults. An empty device UID means "follow the system default".
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: Keys.input); rememberNames() } }
    @Published var outputDeviceUID: String { didSet { defaults.set(outputDeviceUID, forKey: Keys.output); rememberNames() } }
    /// Names of the chosen devices, to recognise them if their UIDs change and to label them while disconnected.
    @Published private(set) var inputDeviceName: String { didSet { defaults.set(inputDeviceName, forKey: Keys.inputName) } }
    @Published private(set) var outputDeviceName: String { didSet { defaults.set(outputDeviceName, forKey: Keys.outputName) } }
    @Published var passThrough: Bool { didSet { defaults.set(passThrough, forKey: Keys.passThrough) } }
    @Published var transcriptsFolder: URL { didSet { defaults.set(transcriptsFolder.path, forKey: Keys.folder) } }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Yapr", isDirectory: true)
    }

    private enum Keys {
        static let input = "inputDeviceUID", output = "outputDeviceUID", passThrough = "passThrough", folder = "transcriptsFolder"
        static let inputName = "inputDeviceName", outputName = "outputDeviceName"
    }

    private init() {
        inputDeviceUID = defaults.string(forKey: Keys.input) ?? ""
        outputDeviceUID = defaults.string(forKey: Keys.output) ?? ""
        inputDeviceName = defaults.string(forKey: Keys.inputName) ?? ""
        outputDeviceName = defaults.string(forKey: Keys.outputName) ?? ""
        passThrough = defaults.bool(forKey: Keys.passThrough)
        if let path = defaults.string(forKey: Keys.folder), !path.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            transcriptsFolder = Settings.defaultFolder
        }
    }

    /// Points saved choices at the devices as they are connected now (a USB mic on another port has a new UID).
    func reconnectDevices() {
        if let d = AudioDevices.match(uid: inputDeviceUID, name: inputDeviceName, in: AudioDevices.inputs()), d.uid != inputDeviceUID {
            inputDeviceUID = d.uid
        }
        if let d = AudioDevices.match(uid: outputDeviceUID, name: outputDeviceName, in: AudioDevices.outputs()), d.uid != outputDeviceUID {
            outputDeviceUID = d.uid
        }
    }

    private func rememberNames() {
        if let d = AudioDevices.inputs().first(where: { $0.uid == inputDeviceUID }) { inputDeviceName = d.name }
        if let d = AudioDevices.outputs().first(where: { $0.uid == outputDeviceUID }) { outputDeviceName = d.name }
    }
}
