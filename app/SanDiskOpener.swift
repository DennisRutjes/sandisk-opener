import SwiftUI
import AppKit
import Foundation

// MARK: - Process helpers

struct CommandResult {
    var status: Int32
    var output: String
}

func runCommand(_ path: String, _ args: [String], stdin: String? = nil) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    var inPipe: Pipe?
    if let stdin {
        let pipe = Pipe()
        process.standardInput = pipe
        inPipe = pipe
        _ = stdin // keep the parameter name meaningful
    }

    do {
        try process.run()
    } catch {
        return CommandResult(status: -1, output: error.localizedDescription)
    }

    if let stdin, let pipe = inPipe {
        let data = (stdin + "\n").data(using: .utf8) ?? Data()
        try? pipe.fileHandleForWriting.write(contentsOf: data)
        try? pipe.fileHandleForWriting.close()
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    return CommandResult(status: process.terminationStatus,
                         output: (out + err).trimmingCharacters(in: .whitespacesAndNewlines))
}

func parsePlist(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
}

func findVolume(named volumeName: String, diskutil: String) -> VolumeInfo? {
    let result = runCommand(diskutil, ["apfs", "list", "-plist"])
    guard let root = parsePlist(result.output),
          let containers = root["Containers"] as? [[String: Any]] else { return nil }

    for container in containers {
        guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }
        for volume in volumes where (volume["Name"] as? String) == volumeName {
            return VolumeInfo(
                name: volumeName,
                device: volume["DeviceIdentifier"] as? String ?? "",
                locked: (volume["Locked"] as? Bool) ?? false,
                mounted: false,
                mountPoint: nil,
                hint: nil,
                capacityUsed: (volume["CapacityInUse"] as? NSNumber)?.uint64Value
            )
        }
    }
    return nil
}

func mountPoint(fromPlist text: String) -> String? {
    guard let root = parsePlist(text),
          let mountPoint = root["MountPoint"] as? String,
          !mountPoint.isEmpty else { return nil }
    return mountPoint
}

func apfsHint(fromPlist text: String) -> String? {
    guard let root = parsePlist(text),
          let users = root["Users"] as? [[String: Any]] else { return nil }
    for user in users {
        if let hint = user["PasswordHint"] as? String, !hint.isEmpty {
            return hint
        }
    }
    return nil
}

// MARK: - Model

struct VolumeInfo {
    var name: String
    var device: String
    var locked: Bool
    var mounted: Bool
    var mountPoint: String?
    var hint: String?
    var capacityUsed: UInt64?
}

final class DriveModel: ObservableObject {
    @Published var driveFound = false
    @Published var hardwareState = ""
    @Published var hardwareHint = ""
    @Published var volume: VolumeInfo?
    @Published var busy = false
    @Published var errorText: String?
    @Published var lastAction: String?
    @Published var volumeName: String = UserDefaults.standard.string(forKey: "volumeName") ?? "develop" {
        didSet { UserDefaults.standard.set(volumeName, forKey: "volumeName") }
    }

    private let diskutil = "/usr/sbin/diskutil"

    private var cliPath: String {
        if let url = Bundle.main.url(forResource: "sandisk-unlock", withExtension: nil) {
            return url.path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sandisk-unlock").path
    }

    var needsSanDiskPassword: Bool { hardwareState == "0x01" }
    var needsAPFSPassword: Bool { volume?.locked == true }
    var isMounted: Bool { volume?.mounted == true }

    var hardwareLabel: String {
        switch hardwareState {
        case "0x00": return "No lock"
        case "0x01": return "Locked"
        case "0x02": return "Unlocked"
        case "0x06": return "Blocked — attempts exceeded"
        case "0x07": return "No keys"
        default: return driveFound ? "Unknown" : "Not found"
        }
    }

    var hardwareColor: Color {
        switch hardwareState {
        case "0x00", "0x02": return .green
        case "0x01": return .orange
        case "0x06", "0x07": return .red
        default: return .secondary
        }
    }

    var volumeLabel: String {
        guard let volume else { return "Not found" }
        if volume.mounted { return "Mounted at \(volume.mountPoint ?? "/Volumes/\(volume.name)")" }
        if volume.locked { return "APFS locked" }
        return "Unlocked, not mounted"
    }

    var volumeColor: Color {
        guard let volume else { return .red }
        if volume.mounted { return .green }
        if volume.locked { return .orange }
        return .yellow
    }

    var primaryLabel: String {
        if isMounted { return "Open \(volumeName)" }
        if needsSanDiskPassword || needsAPFSPassword { return "Unlock & Open" }
        return "Open \(volumeName)"
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        errorText = nil

        let cli = cliPath
        let du = diskutil
        let wanted = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async {
            let state = runCommand(cli, ["state"])
            let hint = runCommand(cli, ["hint"])
            var found = wanted.isEmpty ? nil : findVolume(named: wanted, diskutil: du)

            if var volume = found {
                volume.mountPoint = mountPoint(fromPlist: runCommand(du, ["info", "-plist", volume.device]).output)
                volume.mounted = volume.mountPoint != nil
                volume.hint = apfsHint(fromPlist: runCommand(du, ["apfs", "listCryptoUsers", "-plist", volume.device]).output)
                found = volume
            }

            DispatchQueue.main.async {
                self.driveFound = state.status == 0
                self.hardwareState = state.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.hardwareHint = hint.status == 0 ? hint.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                self.volume = found
                self.busy = false
                if !self.driveFound {
                    self.errorText = "SanDisk drive not found. Connect it and try again."
                } else if found == nil {
                    self.errorText = "APFS volume '\(wanted)' not found. Change the volume name or connect the drive."
                }
            }
        }
    }

    func openDevelop(sanDiskPassword: String, apfsPassword: String) {
        guard !busy else { return }
        let wanted = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { errorText = "Enter an APFS volume name."; return }
        busy = true
        errorText = nil
        lastAction = nil

        let cli = cliPath
        let du = diskutil

        DispatchQueue.global(qos: .userInitiated).async {
            let stateResult = runCommand(cli, ["state"])
            let state = stateResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

            if stateResult.status != 0 {
                self.fail("SanDisk drive not found. Connect it and try again.")
                return
            }

            if state == "0x01" {
                if sanDiskPassword.isEmpty {
                    self.fail("Enter the SanDisk password.")
                    return
                }
                let unlocked = runCommand(cli, ["unlock", "--stdin"], stdin: sanDiskPassword)
                if unlocked.status != 0 {
                    self.fail("SanDisk unlock failed. One attempt may have been used. Do not retry blindly.\n\n\(unlocked.output)")
                    return
                }
            } else if state != "0x00" && state != "0x02" {
                self.fail("Unexpected hardware state \(state). Do not retry; check the drive on another system.")
                return
            }

            guard var volume = findVolume(named: wanted, diskutil: du) else {
                self.fail("APFS volume '\(wanted)' not found. Is the data drive connected?")
                return
            }

            volume.mountPoint = mountPoint(fromPlist: runCommand(du, ["info", "-plist", volume.device]).output)
            volume.mounted = volume.mountPoint != nil

            if volume.locked {
                if apfsPassword.isEmpty {
                    self.fail("Enter the APFS / FileVault passphrase.")
                    return
                }
                let unlocked = runCommand(du, ["apfs", "unlockVolume", volume.device, "-stdinpassphrase"],
                                          stdin: apfsPassword)
                if unlocked.status != 0 {
                    self.fail("APFS unlock failed.\n\n\(unlocked.output)")
                    return
                }
                volume.mountPoint = mountPoint(fromPlist: runCommand(du, ["info", "-plist", volume.device]).output)
                volume.mounted = volume.mountPoint != nil
            }

            if !volume.mounted {
                _ = runCommand(du, ["mount", volume.device])
                volume.mountPoint = mountPoint(fromPlist: runCommand(du, ["info", "-plist", volume.device]).output)
                volume.mounted = volume.mountPoint != nil
            }

            guard let mountPoint = volume.mountPoint else {
                self.fail("Volume unlocked but not mounted. Open Disk Utility and mount '\(wanted)'.")
                return
            }

            DispatchQueue.main.async {
                self.busy = false
                self.lastAction = "Opened \(mountPoint)"
                self.refresh()
                NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
            }
        }
    }

    func openMountedVolume() {
        guard let mountPoint = volume?.mountPoint else {
            errorText = "The volume is not mounted."
            return
        }
        lastAction = "Opened \(mountPoint)"
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.busy = false
            self.errorText = message
        }
    }
}

// MARK: - Views

struct StatusRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct ContentView: View {
    @StateObject private var model = DriveModel()
    @State private var sanDiskPassword = ""
    @State private var apfsPassword = ""

    private var hints: [(String, String)] {
        var result: [(String, String)] = []
        if !model.hardwareHint.isEmpty {
            result.append(("SanDisk", model.hardwareHint))
        }
        if let hint = model.volume?.hint, !hint.isEmpty {
            result.append(("APFS", hint))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard
            if !hints.isEmpty { hintsCard }
            if model.needsSanDiskPassword {
                passwordBlock(title: "SanDisk password",
                              hint: model.hardwareHint.isEmpty ? nil : "Hint: \(model.hardwareHint)",
                              text: $sanDiskPassword,
                              placeholder: "Drive password")
            }
            if model.needsAPFSPassword {
                passwordBlock(title: "APFS / FileVault passphrase",
                              hint: model.volume?.hint.map { "Hint: \($0)" },
                              text: $apfsPassword,
                              placeholder: "APFS passphrase")
            }
            actionRow
            if let error = model.errorText { errorCard(error) }
            if let last = model.lastAction, model.errorText == nil { successCard(last) }
            footer
        }
        .padding(24)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
        .onChange(of: model.lastAction) { _ in
            sanDiskPassword = ""
            apfsPassword = ""
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .teal],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SanDisk Opener")
                    .font(.title2.weight(.semibold))
                Text("Extreme 55AE · native arm64")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh status")
            .disabled(model.busy)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusRow(title: "Drive", value: model.driveFound ? "Connected" : "Not found",
                      color: model.driveFound ? .green : .red)
            StatusRow(title: "Hardware lock", value: model.hardwareLabel, color: model.hardwareColor)
            StatusRow(title: "Volume \(model.volumeName)", value: model.volumeLabel, color: model.volumeColor)
            if let used = model.volume?.capacityUsed {
                StatusRow(title: "Data used",
                          value: ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file),
                          color: .secondary)
            }
            HStack(spacing: 8) {
                Text("Volume name")
                    .font(.callout)
                    .foregroundColor(.secondary)
                TextField("develop", text: $model.volumeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 168)
                    .onSubmit { model.refresh() }
                Text("APFS volume")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var hintsCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text("Password hints")
                    .font(.subheadline.weight(.semibold))
                ForEach(hints.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text(hints[index].0)
                            .foregroundColor(.secondary)
                            .frame(width: 62, alignment: .leading)
                        Text(hints[index].1)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.08)))
    }

    private func passwordBlock(title: String, hint: String?, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                if model.isMounted {
                    model.openMountedVolume()
                } else {
                    model.openDevelop(sanDiskPassword: sanDiskPassword,
                                      apfsPassword: apfsPassword)
                }
            } label: {
                HStack(spacing: 8) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.primaryLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy)

            Button("Refresh") {
                model.refresh()
            }
            .controlSize(.large)
            .disabled(model.busy)
        }
        .padding(.top, 2)
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
    }

    private func successCard(_ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(text)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    private var footer: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("No erase · No format · No firmware")
            }
            Text("Unofficial · not affiliated with SanDisk or Western Digital")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

@main
struct SanDiskOpenerApp: App {
    var body: some Scene {
        WindowGroup("SanDisk Opener") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
