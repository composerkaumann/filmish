import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    private enum FocusField: Hashable {
        case chooseFolder
        case rescan
        case totalDuration
        case frameRate
        case fadeInToggle
        case fadeInDuration
        case sameFadesToggle
        case resetOrder
        case transitionType(UUID)
        case transitionDuration(UUID)
        case fixedDisplay(UUID)
        case fadeOutToggle
        case fadeOutDuration
        case chooseOutput
        case createMP4
    }

    @EnvironmentObject private var model: AppModel
    @State private var draggedImageID: UUID?
    @FocusState private var focusedField: FocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            dependencySection
            folderSection
            optionsSection
            fadeInSection
            sameFadesSection
            imageSection
            fadeOutSection
            outputSection
            statusSection
            actionSection
        }
        .padding(20)
        .onAppear {
            if focusedField == nil {
                focusedField = .totalDuration
            }
        }
    }

    @ViewBuilder
    private var dependencySection: some View {
        if !model.dependenciesAvailable {
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(model.missingDependencyNames) Not Found")
                            .font(.headline)
                        Text("Install Homebrew from brew.sh if needed, then open Terminal and run:")
                            .foregroundStyle(.secondary)
                        Text("brew install ffmpeg")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        HStack(spacing: 14) {
                            Link("Install Homebrew", destination: URL(string: "https://brew.sh")!)
                            Link("FFmpeg Formula", destination: URL(string: "https://formulae.brew.sh/formula/ffmpeg")!)
                            Button("Check Again") { model.refreshDependencies() }
                        }
                        Text("After installation, click Check Again. Both FFmpeg and FFprobe are installed by the same Homebrew package.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Filmish")
                .font(.largeTitle.weight(.semibold))
            Text("Turn still images into something suspiciously movie-like.")
                .foregroundStyle(.secondary)
        }
    }

    private var folderSection: some View {
        HStack {
            Button("Choose Image Folder…") { model.chooseInputFolder() }
                .focused($focusedField, equals: .chooseFolder)
            Text(model.inputFolder?.path ?? "No folder selected")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(model.inputFolder == nil ? .secondary : .primary)
            Spacer()
            Button("Rescan") { model.scanAgain() }
                .disabled(model.inputFolder == nil || model.isScanning || model.isRendering)
                .focused($focusedField, equals: .rescan)
        }
    }

    private var fadeInSection: some View {
        GroupBox("Start of Video") {
            HStack(spacing: 16) {
                Toggle("Fade in from black", isOn: $model.fadeInEnabled)
                    .toggleStyle(.checkbox)
                    .focused($focusedField, equals: .fadeInToggle)
                Spacer()
                fadeTimeEditor(
                    seconds: $model.fadeInDurationSeconds,
                    enabled: model.fadeInEnabled,
                    focus: .fadeInDuration
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var sameFadesSection: some View {
        GroupBox("Between Images") {
            HStack(spacing: 10) {
                Toggle(
                    "Use the same fade between all images",
                    isOn: Binding(
                        get: { model.sameFadesEnabled },
                        set: { model.setSameFadesEnabled($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .focused($focusedField, equals: .sameFadesToggle)
                Text(model.sameFadesEnabled
                     ? "Changing one row updates every fade."
                     : "Each row can use its own fade type and time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private var imageSection: some View {
        GroupBox {
            if model.isScanning {
                ProgressView("Reading image dimensions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.images.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Images").font(.headline)
                    Text("Choose a folder containing JPG, PNG, WebP, BMP, or TIFF images.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("#").fontWeight(.semibold).frame(width: 28, alignment: .trailing)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("Preview").fontWeight(.semibold).frame(width: 54)
                        Text("File").fontWeight(.semibold)
                        Spacer()
                        Text("Fade Type").fontWeight(.semibold).frame(width: 145, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Fade Time").fontWeight(.semibold)
                            Text("seconds")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 100, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Clear Display").fontWeight(.semibold)
                            Text("seconds; blank = Auto")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 145, alignment: .leading)
                        Text("Dimensions").fontWeight(.semibold).frame(width: 95, alignment: .trailing)
                        Text("").frame(width: 18)
                        Text("Action").fontWeight(.semibold).frame(width: 68)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    Divider()
                    List(Array(model.images.enumerated()), id: \.element.id) { index, image in
                        HStack {
                            Text("\(index + 1)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            ImageThumbnail(url: image.url)
                            Text(image.name).lineLimit(1)
                            Spacer()
                            if index < model.images.count - 1 {
                                Picker("Fade type", selection: transitionNameBinding(for: image.id)) {
                                    ForEach(model.transitions, id: \.self) { transition in
                                        Text(transition == "none" ? "None (hard cut)" : transition)
                                            .tag(transition)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 145)
                                .focused($focusedField, equals: .transitionType(image.id))

                                secondsField(
                                    placeholder: "1.0",
                                    accessibilityLabel: "Fade duration in seconds",
                                    value: transitionDurationBinding(for: image.id),
                                    focus: .transitionDuration(image.id)
                                )
                                .frame(width: 100, alignment: .leading)
                                .disabled(image.transitionName == "none")
                            } else {
                                Text("End of slideshow")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 145, alignment: .leading)
                                Text("—")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 100, alignment: .leading)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                fixedDisplayField(for: image.id)
                                if let actual = model.actualClearDisplayText(for: image.id) {
                                    Text("Actual: \(actual) s")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                } else {
                                    Text("Actual: —")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 145, alignment: .leading)
                            Text(image.dimensions)
                                .monospacedDigit()
                                .foregroundColor(image.isReadable ? Color.secondary : Color.red)
                                .frame(width: 95, alignment: .trailing)
                            Image(systemName: image.isReadable ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(image.isReadable ? Color.secondary : Color.red)
                                .help(image.probeError ?? "Image dimensions read successfully.")
                                .frame(width: 18)
                            Button("Remove") {
                                model.removeImage(image.id)
                            }
                            .frame(width: 68)
                            .disabled(model.isRendering)
                            .help("Remove this image from the slideshow. The image file will not be deleted.")
                        }
                        .contentShape(Rectangle())
                        .onDrag {
                            draggedImageID = image.id
                            return NSItemProvider(object: image.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: ImageReorderDropDelegate(
                                destinationID: image.id,
                                images: $model.images,
                                draggedImageID: $draggedImageID
                            )
                        )
                    }
                    .listStyle(.plain)
                }
            }
        } label: {
            HStack {
                Text("Images (\(model.images.count))")
                Text("Drag rows to reorder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Alphabetical") { model.resetToAlphabeticalOrder() }
                    .disabled(model.images.count < 2 || model.isAlphabeticalOrder || model.isRendering)
                    .focused($focusedField, equals: .resetOrder)
            }
        }
        .frame(minHeight: 190)
    }

    private var fadeOutSection: some View {
        GroupBox("End of Video") {
            HStack(spacing: 16) {
                Toggle("Fade out to black", isOn: $model.fadeOutEnabled)
                    .toggleStyle(.checkbox)
                    .focused($focusedField, equals: .fadeOutToggle)
                Spacer()
                fadeTimeEditor(
                    seconds: $model.fadeOutDurationSeconds,
                    enabled: model.fadeOutEnabled,
                    focus: .fadeOutDuration
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var optionsSection: some View {
        GroupBox("Video Options") {
            HStack(spacing: 14) {
                Text("Total duration")
                DecimalSecondsTextField(
                    value: $model.durationSeconds,
                    placeholder: "Seconds",
                    accessibilityLabel: "Total duration in seconds",
                    isFocused: focusedField == .totalDuration,
                    onFocus: { focusedField = .totalDuration },
                    onTab: advanceFocus
                )
                    .frame(width: 72)
                Stepper("seconds", value: $model.durationSeconds, in: 0.1...86_400, step: 0.1)
                    .labelsHidden()
                Text("seconds")
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 8)

                Text("Frame rate")
                Picker("Frame rate", selection: $model.frameRate) {
                    Text("24 fps").tag(24)
                    Text("25 fps").tag(25)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .focused($focusedField, equals: .frameRate)
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private func fadeTimeEditor(seconds: Binding<Double>, enabled: Bool, focus: FocusField) -> some View {
        HStack(spacing: 7) {
            Text("Duration")
                .foregroundStyle(.secondary)
            secondsField(
                placeholder: "1.0",
                accessibilityLabel: "Fade duration in seconds",
                value: seconds,
                focus: focus
            )
            Text("seconds")
                .foregroundStyle(.secondary)
        }
        .disabled(!enabled)
    }

    private func transitionNameBinding(for imageID: UUID) -> Binding<String> {
        Binding(
            get: { model.images.first(where: { $0.id == imageID })?.transitionName ?? "none" },
            set: { model.setTransitionName($0, for: imageID) }
        )
    }

    private func transitionDurationBinding(for imageID: UUID) -> Binding<Double> {
        Binding(
            get: { model.images.first(where: { $0.id == imageID })?.transitionDurationSeconds ?? 1.0 },
            set: { model.setTransitionDuration($0, for: imageID) }
        )
    }

    private func fixedDisplayBinding(for imageID: UUID) -> Binding<String> {
        Binding(
            get: { model.images.first(where: { $0.id == imageID })?.fixedDisplaySecondsText ?? "" },
            set: { model.setFixedDisplaySecondsText($0, for: imageID) }
        )
    }

    private func secondsField(
        placeholder: String,
        accessibilityLabel: String,
        value: Binding<Double>,
        focus: FocusField
    ) -> some View {
        HStack(spacing: 4) {
            DecimalSecondsTextField(
                value: value,
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                isFocused: focusedField == focus,
                onFocus: { focusedField = focus },
                onTab: advanceFocus
            )
                .frame(width: 62, height: 25)
        }
    }

    private func fixedDisplayField(for imageID: UUID) -> some View {
        TabAwareStringTextField(
            value: fixedDisplayBinding(for: imageID),
            placeholder: "Auto",
            accessibilityLabel: "Clear display time in seconds; leave blank for Auto",
            isFocused: focusedField == .fixedDisplay(imageID),
            onFocus: { focusedField = .fixedDisplay(imageID) },
            onTab: advanceFocus
        )
            .frame(width: 78, height: 25)
            .help("Clear display time for this image. Leave blank to divide the remaining time automatically. Fades are not included.")
    }

    private var outputSection: some View {
        HStack {
            Button("Choose Output…") { model.chooseOutputFile() }
                .focused($focusedField, equals: .chooseOutput)
            Text(model.outputURL?.path ?? "No output selected")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(model.outputURL == nil ? .secondary : .primary)
            Spacer()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let message = model.validationMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if model.isRendering {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.progress)
                Text("Rendering… \(Int(model.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let output = model.finishedOutput {
            HStack {
                Label("Finished: \(output.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Show in Finder") { model.revealOutput() }
            }
        }
    }

    private var actionSection: some View {
        HStack {
            DisclosureGroup("Technical log") {
                ScrollView {
                    Text(model.logText.isEmpty ? "No rendering log yet." : model.logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 90)
                .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
            if model.isRendering {
                Button("Cancel", role: .destructive) { model.cancelRendering() }
            }
            Button("Create MP4") { model.render() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRender)
                .focused($focusedField, equals: .createMP4)
        }
    }

    private var focusOrder: [FocusField] {
        var order: [FocusField] = [.totalDuration]
        if model.fadeInEnabled { order.append(.fadeInDuration) }
        for (index, image) in model.images.enumerated() {
            if index < model.images.count - 1, image.transitionName != "none" {
                order.append(.transitionDuration(image.id))
            }
            order.append(.fixedDisplay(image.id))
        }
        if model.fadeOutEnabled { order.append(.fadeOutDuration) }
        return order
    }

    private func advanceFocus(_ reverse: Bool) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let current = focusedField,
              let index = order.firstIndex(of: current) else {
            focusedField = reverse ? order.last : order.first
            return
        }
        let next = reverse
            ? (index - 1 + order.count) % order.count
            : (index + 1) % order.count
        focusedField = order[next]
    }
}

private final class TabNavigatingTextField: NSTextField {
    var onTab: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48,
           modifiers.intersection([.command, .control, .option]).isEmpty {
            onTab?(modifiers.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }
}

private struct DecimalSecondsTextField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let placeholder: String
    let accessibilityLabel: String
    let isFocused: Bool
    let onFocus: () -> Void
    let onTab: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TabNavigatingTextField {
        let field = TabNavigatingTextField()
        configure(field)
        field.stringValue = Self.formatted(value)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: TabNavigatingTextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        let ownsFocus = field.window?.firstResponder === field.currentEditor()
        if !ownsFocus {
            field.stringValue = Self.formatted(value)
        }
        if isFocused && !ownsFocus {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window,
                      window.firstResponder !== field.currentEditor() else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    private func configure(_ field: TabNavigatingTextField) {
        field.placeholderString = placeholder
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = isEnabled
        field.onTab = onTab
        field.setAccessibilityLabel(accessibilityLabel)
    }

    private static func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0", text.contains("."), !text.hasSuffix(".0") {
            text.removeLast()
        }
        return text
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DecimalSecondsTextField

        init(parent: DecimalSecondsTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let normalized = field.stringValue.replacingOccurrences(of: ",", with: ".")
            if let number = Double(normalized), number.isFinite {
                parent.value = number
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.stringValue = DecimalSecondsTextField.formatted(parent.value)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab(false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onTab(true)
                return true
            }
            return false
        }
    }
}

private struct TabAwareStringTextField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: String
    let placeholder: String
    let accessibilityLabel: String
    let isFocused: Bool
    let onFocus: () -> Void
    let onTab: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TabNavigatingTextField {
        let field = TabNavigatingTextField()
        configure(field)
        field.stringValue = value
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: TabNavigatingTextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        let ownsFocus = field.window?.firstResponder === field.currentEditor()
        if !ownsFocus {
            field.stringValue = value
        }
        if isFocused && !ownsFocus {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window,
                      window.firstResponder !== field.currentEditor() else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    private func configure(_ field: TabNavigatingTextField) {
        field.placeholderString = placeholder
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = isEnabled
        field.onTab = onTab
        field.setAccessibilityLabel(accessibilityLabel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabAwareStringTextField

        init(parent: TabAwareStringTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.value = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab(false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onTab(true)
                return true
            }
            return false
        }
    }
}

private struct ImageReorderDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var images: [ImageInfo]
    @Binding var draggedImageID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedImageID else { return }

        withAnimation {
            AppModel.moveImage(&images, id: draggedImageID, onto: destinationID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedImageID = nil
        return true
    }
}

private struct ImageThumbnail: View {
    private let thumbnail: NSImage?

    init(url: URL) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 88
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            thumbnail = NSImage(cgImage: image, size: .zero)
        } else {
            thumbnail = nil
        }
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .clipped()
        .frame(width: 54)
    }
}
