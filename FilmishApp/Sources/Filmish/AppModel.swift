import AppKit
import Foundation
import ImageIO

struct ImageInfo: Identifiable, Sendable {
    var id = UUID()
    let name: String
    let url: URL
    let dimensions: String
    let width: Int?
    let height: Int?
    let probeError: String?
    var transitionName = "none"
    var transitionDurationSeconds = 1.0
    var fixedDisplaySecondsText = ""

    var isReadable: Bool { width != nil && height != nil }
}

enum HoldAllocationError: Error, Equatable {
    case fixedTimesExceedAvailable
    case automaticTimesTooShort
    case allFixedTimesDoNotMatch
}

@MainActor
final class AppModel: ObservableObject {
    @Published var inputFolder: URL?
    @Published var outputURL: URL?
    @Published var images: [ImageInfo] = []
    @Published var transitions: [String] = ["none"]
    @Published var sameFadesEnabled = true
    @Published var durationSeconds = 10.0
    @Published var frameRate = 30
    @Published var fadeInEnabled = false
    @Published var fadeOutEnabled = false
    @Published var fadeInDurationSeconds = 1.0
    @Published var fadeOutDurationSeconds = 1.0
    @Published var isScanning = false
    @Published var isRendering = false
    @Published var progress = 0.0
    @Published var logText = ""
    @Published var errorMessage: String?
    @Published var finishedOutput: URL?
    @Published private(set) var ffmpegAvailable = false
    @Published private(set) var ffprobeAvailable = false

    private var renderProcess: Process?

    init() {
        refreshDependencies()
    }

    var dependenciesAvailable: Bool { ffmpegAvailable && ffprobeAvailable }
    var missingDependencyNames: String {
        var missing: [String] = []
        if !ffmpegAvailable { missing.append("FFmpeg") }
        if !ffprobeAvailable { missing.append("FFprobe") }
        return missing.joined(separator: " and ")
    }
    var isAlphabeticalOrder: Bool {
        images.map(\.url.path) == Self.alphabeticallySorted(images).map(\.url.path)
    }

    func actualClearDisplayText(for imageID: UUID) -> String? {
        guard let index = images.firstIndex(where: { $0.id == imageID }),
              durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }

        let transitionFrames = images.dropLast().reduce(into: 0) { total, image in
            guard image.transitionName != "none",
                  image.transitionDurationSeconds.isFinite,
                  image.transitionDurationSeconds > 0 else { return }
            total += Self.roundedFrames(seconds: image.transitionDurationSeconds, fps: frameRate)
        }
        guard (!fadeInEnabled || (fadeInDurationSeconds.isFinite && fadeInDurationSeconds > 0)),
              (!fadeOutEnabled || (fadeOutDurationSeconds.isFinite && fadeOutDurationSeconds > 0)) else {
            return nil
        }
        let edgeFadeFrames = (fadeInEnabled ? Self.roundedFrames(seconds: fadeInDurationSeconds, fps: frameRate) : 0)
            + (fadeOutEnabled ? Self.roundedFrames(seconds: fadeOutDurationSeconds, fps: frameRate) : 0)
        let fixedTimes = images.map { image -> Double? in
            let value = image.fixedDisplaySecondsText.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : Self.parseDecimalSeconds(value)
        }
        guard fixedTimes.enumerated().allSatisfy({ offset, seconds in
            images[offset].fixedDisplaySecondsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || seconds != nil
        }) else {
            return nil
        }

        let allocation = Self.allocateHoldFrames(
            totalFrames: Self.roundedFrames(seconds: durationSeconds, fps: frameRate),
            transitionFrames: transitionFrames + edgeFadeFrames,
            fixedDisplaySeconds: fixedTimes,
            fps: frameRate
        )
        guard case .success(let frames) = allocation else { return nil }
        return Self.secondsDisplay(Double(frames[index]) / Double(frameRate))
    }

    var validationMessage: String? {
        if !dependenciesAvailable {
            return "\(missingDependencyNames) must be installed before creating a video."
        }
        if isScanning { return "Reading image dimensions…" }
        if inputFolder == nil { return "Choose a folder containing images." }
        if images.isEmpty { return "The selected folder contains no supported images." }
        if images.contains(where: { !$0.isReadable }) {
            return "One or more images could not be read. See the image list."
        }

        let sizes = Set(images.map(\.dimensions))
        if sizes.count > 1 { return "Image dimensions differ. All images must have the same dimensions." }
        if let first = images.first, let width = first.width, let height = first.height,
           (width % 2 != 0 || height % 2 != 0) {
            return "Image width and height must both be even for yuv420p video."
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return "Total duration must be a positive number of seconds."
        }
        let totalFrames = Self.roundedFrames(seconds: durationSeconds, fps: frameRate)
        if totalFrames < 1 {
            return "Total duration is too short at \(frameRate) fps."
        }
        if outputURL == nil { return "Choose an output MP4 file." }

        var allTransitionFrames = 0
        for (index, image) in images.dropLast().enumerated() where image.transitionName != "none" {
            if !transitions.contains(image.transitionName) {
                return "Fade \(index + 1) uses a transition that is not available in this FFmpeg installation."
            }
            guard image.transitionDurationSeconds.isFinite, image.transitionDurationSeconds > 0 else {
                return "Fade \(index + 1) must have a positive duration in seconds."
            }
            let transitionFrames = Self.roundedFrames(seconds: image.transitionDurationSeconds, fps: frameRate)
            if transitionFrames < 1 {
                return "Fade \(index + 1) is too short at \(frameRate) fps."
            }
            allTransitionFrames += transitionFrames
        }

        if let error = edgeFadeValidation(
            enabled: fadeInEnabled,
            seconds: fadeInDurationSeconds,
            label: "Fade-in"
        ) { return error }
        if let error = edgeFadeValidation(
            enabled: fadeOutEnabled,
            seconds: fadeOutDurationSeconds,
            label: "Fade-out"
        ) { return error }
        let edgeFadeFrames = (fadeInEnabled ? Self.roundedFrames(seconds: fadeInDurationSeconds, fps: frameRate) : 0)
            + (fadeOutEnabled ? Self.roundedFrames(seconds: fadeOutDurationSeconds, fps: frameRate) : 0)
        if edgeFadeFrames > totalFrames {
            return "Fade-in and fade-out durations must not overlap."
        }

        var fixedDisplaySeconds: [Double?] = []
        for (index, image) in images.enumerated() {
            let value = image.fixedDisplaySecondsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                fixedDisplaySeconds.append(nil)
                continue
            }
            guard let seconds = Self.parseDecimalSeconds(value) else {
                return "Clear display time for image \(index + 1) must be a positive decimal number, such as 1.2, or left blank for Auto."
            }
            if Self.roundedFrames(seconds: seconds, fps: frameRate) < 1 {
                return "Clear display time for image \(index + 1) is too short at \(frameRate) fps."
            }
            fixedDisplaySeconds.append(seconds)
        }

        switch Self.allocateHoldFrames(
            totalFrames: totalFrames,
            transitionFrames: allTransitionFrames + edgeFadeFrames,
            fixedDisplaySeconds: fixedDisplaySeconds,
            fps: frameRate
        ) {
        case .success:
            break
        case .failure(.fixedTimesExceedAvailable):
            return "The fixed clear display times and fades exceed the total video duration."
        case .failure(.automaticTimesTooShort):
            return "The fixed clear display times and fades leave no usable time for every Auto image."
        case .failure(.allFixedTimesDoNotMatch):
            return "Every image has a fixed clear display time, but those times and the fades do not match the total video duration. Leave at least one image on Auto or adjust the times."
        }

        return nil
    }

    var canRender: Bool {
        validationMessage == nil && !isRendering
    }

    private func edgeFadeValidation(enabled: Bool, seconds: Double, label: String) -> String? {
        guard enabled else { return nil }
        if !seconds.isFinite || seconds <= 0 { return "\(label) must have a positive duration in seconds." }
        if Self.roundedFrames(seconds: seconds, fps: frameRate) < 1 {
            return "\(label) is too short at \(frameRate) fps."
        }
        return nil
    }

    private func updateFade(for imageID: UUID, change: (inout ImageInfo) -> Void) {
        guard let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        change(&images[index])
        guard sameFadesEnabled else { return }

        let source = images[index]
        for otherIndex in images.indices where otherIndex != index {
            images[otherIndex].transitionName = source.transitionName
            images[otherIndex].transitionDurationSeconds = source.transitionDurationSeconds
        }
    }

    private func synchronizeFadeSettings() {
        guard let source = images.first else { return }
        for index in images.indices.dropFirst() {
            images[index].transitionName = source.transitionName
            images[index].transitionDurationSeconds = source.transitionDurationSeconds
        }
    }

    func chooseInputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Image Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.inputFolder = url
                self.outputURL = url.appendingPathComponent("filmish.mp4")
                self.finishedOutput = nil
                self.images = []
                await self.scanImages(in: url, preservingCurrentOrder: false)
            }
        }
    }

    func chooseOutputFile() {
        let panel = NSSavePanel()
        panel.title = "Choose Output MP4"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "filmish.mp4"
        panel.directoryURL = outputURL?.deletingLastPathComponent() ?? inputFolder
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.outputURL = url.pathExtension.lowercased() == "mp4" ? url : url.appendingPathExtension("mp4")
                self.finishedOutput = nil
            }
        }
    }

    func scanAgain() {
        guard let inputFolder else { return }
        Task { await scanImages(in: inputFolder, preservingCurrentOrder: true) }
    }

    func scanImages(in folder: URL, preservingCurrentOrder: Bool = true) async {
        let previousImages = preservingCurrentOrder ? images : []
        isScanning = true
        errorMessage = nil
        let result = await Task.detached(priority: .userInitiated) {
            Self.scanFolder(folder)
        }.value
        images = Self.mergeScannedImages(result, preserving: previousImages)
        if sameFadesEnabled { synchronizeFadeSettings() }
        isScanning = false
    }

    func resetToAlphabeticalOrder() {
        images = Self.alphabeticallySorted(images)
    }

    func refreshDependencies() {
        ffmpegAvailable = Self.ffmpegURL(named: "ffmpeg") != nil
        ffprobeAvailable = Self.ffmpegURL(named: "ffprobe") != nil

        if dependenciesAvailable {
            Task { await loadTransitions() }
        } else {
            transitions = ["none"]
        }
    }

    func loadTransitions() async {
        let loaded = await Task.detached {
            Self.readTransitions()
        }.value
        if !loaded.isEmpty {
            transitions = ["none"] + loaded
        }
    }

    func setSameFadesEnabled(_ enabled: Bool) {
        sameFadesEnabled = enabled
        if enabled { synchronizeFadeSettings() }
    }

    func setTransitionName(_ name: String, for imageID: UUID) {
        updateFade(for: imageID) { $0.transitionName = name }
    }

    func setTransitionDuration(_ seconds: Double, for imageID: UUID) {
        updateFade(for: imageID) { $0.transitionDurationSeconds = seconds }
    }

    func setFixedDisplaySecondsText(_ text: String, for imageID: UUID) {
        guard let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        images[index].fixedDisplaySecondsText = text
    }

    func removeImage(_ imageID: UUID) {
        guard !isRendering else { return }
        images.removeAll { $0.id == imageID }
    }

    func render() {
        guard canRender, let inputFolder, let outputURL,
              let worker = Self.workerScriptURL() else {
            if Self.workerScriptURL() == nil {
                errorMessage = "The bundled filmish.sh worker could not be found."
            }
            return
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace Existing File?"
            alert.informativeText = "A file named “\(outputURL.lastPathComponent)” already exists. Replacing it cannot be undone."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        var arguments = [
            worker.path,
            "--input", inputFolder.path,
            "--duration", Self.secondsArgument(durationSeconds),
            "--fps", String(frameRate),
            "--output", outputURL.path,
            "--overwrite"
        ]
        for image in images {
            arguments += ["--image", image.name]
        }
        for image in images {
            let text = image.fixedDisplaySecondsText.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = Self.parseDecimalSeconds(text).map(Self.secondsArgument) ?? "auto"
            arguments += ["--hold-time", value]
        }
        for image in images.dropLast() {
            let time = image.transitionName == "none"
                ? "0"
                : Self.secondsArgument(image.transitionDurationSeconds)
            arguments += ["--transition-spec", image.transitionName, time]
        }
        if fadeInEnabled {
            arguments += ["--fade-in", Self.secondsArgument(fadeInDurationSeconds)]
        }
        if fadeOutEnabled {
            arguments += ["--fade-out", Self.secondsArgument(fadeOutDurationSeconds)]
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        process.currentDirectoryURL = inputFolder
        process.standardOutput = pipe
        process.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        logText = ""
        errorMessage = nil
        finishedOutput = nil
        progress = 0
        isRendering = true
        renderProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consumeOutput(chunk)
            }
        }

        process.terminationHandler = { [weak self] completed in
            pipe.fileHandleForReading.readabilityHandler = nil
            let trailingData = pipe.fileHandleForReading.readDataToEndOfFile()
            let trailing = String(data: trailingData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self else { return }
                if !trailing.isEmpty { self.consumeOutput(trailing) }
                self.renderProcess = nil
                self.isRendering = false
                if completed.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outputURL.path) {
                    self.progress = 1
                    self.finishedOutput = outputURL
                } else if completed.terminationReason == .uncaughtSignal {
                    self.errorMessage = "Rendering was cancelled."
                } else {
                    self.errorMessage = self.lastErrorLine() ?? "FFmpeg rendering failed."
                }
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            renderProcess = nil
            isRendering = false
            errorMessage = "Could not start the rendering process: \(error.localizedDescription)"
        }
    }

    func cancelRendering() {
        renderProcess?.terminate()
    }

    func revealOutput() {
        guard let finishedOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finishedOutput])
    }

    private func consumeOutput(_ chunk: String) {
        logText += chunk
        for line in logText.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "PROGRESS",
               let current = Double(parts[1]), let total = Double(parts[2]), total > 0 {
                progress = min(max(current / total, 0), 1)
                break
            }
        }
    }

    private func lastErrorLine() -> String? {
        logText.split(separator: "\n")
            .map(String.init)
            .last(where: { $0.hasPrefix("ERROR:") })
    }

    nonisolated private static func workerScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "filmish", withExtension: "sh") {
            return bundled
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("filmish.sh")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    nonisolated private static func ffmpegURL(named name: String) -> URL? {
        var prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            prefixes.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for prefix in prefixes {
            let url = URL(fileURLWithPath: prefix).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    nonisolated static func scanFolder(_ folder: URL) -> [ImageInfo] {
        let supported = Set(["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff"])
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let imageURLs = urls.filter { url in
            guard supported.contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard let ffprobe = ffmpegURL(named: "ffprobe") else {
            return imageURLs.map {
                if let size = imageIODimensions(for: $0) {
                    return ImageInfo(name: $0.lastPathComponent, url: $0, dimensions: "\(size.width)×\(size.height)", width: size.width, height: size.height, probeError: nil)
                }
                return ImageInfo(name: $0.lastPathComponent, url: $0, dimensions: "UNREADABLE", width: nil, height: nil, probeError: "FFprobe was not found and macOS ImageIO could not read the file.")
            }
        }

        return imageURLs.map { url in
            let result = runSync(
                executable: ffprobe,
                arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", "--", url.path]
            )
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "x")
                if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) {
                    return ImageInfo(name: url.lastPathComponent, url: url, dimensions: "\(width)×\(height)", width: width, height: height, probeError: nil)
                }
            }

            if let size = imageIODimensions(for: url) {
                return ImageInfo(name: url.lastPathComponent, url: url, dimensions: "\(size.width)×\(size.height)", width: size.width, height: size.height, probeError: nil)
            }

            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? "Neither FFprobe nor macOS ImageIO could read this file." : detail
            return ImageInfo(name: url.lastPathComponent, url: url, dimensions: "UNREADABLE", width: nil, height: nil, probeError: reason)
        }
    }

    nonisolated static func alphabeticallySorted(_ images: [ImageInfo]) -> [ImageInfo] {
        images.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func mergeScannedImages(_ scanned: [ImageInfo], preserving previous: [ImageInfo]) -> [ImageInfo] {
        guard !previous.isEmpty else { return alphabeticallySorted(scanned) }

        let previousByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.url.path, $0) })
        let scannedByPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.url.path, $0) })
        let preserved = previous.compactMap { old -> ImageInfo? in
            guard var refreshed = scannedByPath[old.url.path] else { return nil }
            refreshed.id = old.id
            refreshed.transitionName = old.transitionName
            refreshed.transitionDurationSeconds = old.transitionDurationSeconds
            refreshed.fixedDisplaySecondsText = old.fixedDisplaySecondsText
            return refreshed
        }
        let newImages = alphabeticallySorted(scanned.filter { previousByPath[$0.url.path] == nil })
        return preserved + newImages
    }

    nonisolated static func moveImage(_ images: inout [ImageInfo], id: UUID, onto destinationID: UUID) {
        guard id != destinationID,
              let sourceIndex = images.firstIndex(where: { $0.id == id }),
              let destinationIndex = images.firstIndex(where: { $0.id == destinationID }) else {
            return
        }
        images.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
        )
    }

    nonisolated static func roundedFrames(seconds: Double, fps: Int) -> Int {
        Int((seconds * Double(fps)).rounded())
    }

    nonisolated static func parseDecimalSeconds(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty,
              let value = Double(normalized), value.isFinite, value > 0 else {
            return nil
        }
        return value
    }

    nonisolated static func secondsArgument(_ seconds: Double) -> String {
        var value = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        while value.contains(".") && value.last == "0" { value.removeLast() }
        if value.last == "." { value.removeLast() }
        return value
    }

    nonisolated static func secondsDisplay(_ seconds: Double) -> String {
        var value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        while value.contains(".") && value.last == "0" { value.removeLast() }
        if value.last == "." { value.removeLast() }
        return value
    }

    nonisolated static func allocateHoldFrames(
        totalFrames: Int,
        transitionFrames: Int,
        fixedDisplaySeconds: [Double?],
        fps: Int
    ) -> Result<[Int], HoldAllocationError> {
        let clearBudget = totalFrames - transitionFrames
        var result = Array(repeating: 0, count: fixedDisplaySeconds.count)
        var automaticIndices: [Int] = []
        var fixedTotal = 0

        for (index, seconds) in fixedDisplaySeconds.enumerated() {
            if let seconds {
                let frames = roundedFrames(seconds: seconds, fps: fps)
                result[index] = frames
                fixedTotal += frames
            } else {
                automaticIndices.append(index)
            }
        }

        guard fixedTotal <= clearBudget else { return .failure(.fixedTimesExceedAvailable) }
        let remaining = clearBudget - fixedTotal
        guard !automaticIndices.isEmpty else {
            return remaining == 0 ? .success(result) : .failure(.allFixedTimesDoNotMatch)
        }
        guard remaining >= automaticIndices.count else { return .failure(.automaticTimesTooShort) }

        let base = remaining / automaticIndices.count
        let extra = remaining % automaticIndices.count
        for (offset, index) in automaticIndices.enumerated() {
            result[index] = base + (offset < extra ? 1 : 0)
        }
        return .success(result)
    }

    nonisolated private static func imageIODimensions(for url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    nonisolated private static func readTransitions() -> [String] {
        guard let ffmpeg = ffmpegURL(named: "ffmpeg") else { return [] }
        let result = runSync(executable: ffmpeg, arguments: ["-hide_banner", "-h", "filter=xfade"])
        guard result.status == 0 else { return [] }

        var names: [String] = []
        var reading = false
        for rawLine in result.output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("transition ") {
                reading = true
                continue
            }
            if line.hasPrefix("duration ") { break }
            guard reading else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count >= 2, fields[0] != "custom", Int(fields[1]) != nil {
                names.append(String(fields[0]))
            }
        }
        return names
    }

    nonisolated private static func runSync(executable: URL, arguments: [String]) -> (status: Int32, output: String, errorOutput: String) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return (
                process.terminationStatus,
                String(data: outputData, encoding: .utf8) ?? "",
                String(data: errorData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
