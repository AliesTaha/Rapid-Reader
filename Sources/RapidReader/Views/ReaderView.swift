import AppKit
import RapidReaderCore
import SwiftUI

struct ReaderView: View {
    let item: RapidReaderCore.LibraryItem
    @ObservedObject var library: LibraryStore
    var onFocusChange: (Bool) -> Void = { _ in }

    enum ReaderMode: String, CaseIterable, Identifiable {
        case rsvp = "RSVP"
        case text = "Text"

        var id: String { rawValue }
    }

    @StateObject private var session: ReaderSession
    @AppStorage(ReaderTheme.storageKey) private var theme: ReaderTheme = .system
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var readerMode: ReaderMode = .rsvp
    @State private var showingNotes = false
    @State private var showingSearch = false
    @State private var showingOptions = false
    @State private var searchQuery = ""
    @State private var noteText = ""

    @State private var chromeVisible = true
    @State private var controlsHovered = false
    @State private var hideTask: Task<Void, Never>?
    @State private var speedNotice: Int?
    @State private var speedNoticeTask: Task<Void, Never>?

    init(item: RapidReaderCore.LibraryItem, library: LibraryStore, onFocusChange: @escaping (Bool) -> Void = { _ in }) {
        self.item = item
        self.library = library
        self.onFocusChange = onFocusChange
        _session = StateObject(wrappedValue: ReaderSession(
            sections: item.sections,
            sectionIndex: item.progress.sectionIndex,
            wordIndex: item.progress.wordIndex,
            preferences: item.preferences
        ))
    }

    /// Focus mode leaves only the word and the progress bar while playing.
    private var isFocused: Bool {
        session.preferences.focusMode && session.isPlaying && readerMode == .rsvp
    }

    private func toggleFocusMode() {
        session.preferences.focusMode.toggle()
    }

    private var currentSection: BookSection {
        session.currentSection ?? BookSection(title: item.title, text: "")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            stage

            VStack(spacing: 10) {
                ReaderControls(
                    session: session,
                    showingOptions: $showingOptions,
                    onPlayPause: togglePlayback
                )
                .onHover { hovering in
                    controlsHovered = hovering
                    hovering ? revealChrome() : scheduleChromeHide()
                }

                RemainingTimeLabel(session: session)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .opacity(chromeVisible ? 1 : 0)
            .offset(y: chromeVisible ? 0 : 12)
            .allowsHitTesting(chromeVisible)

            if let speedNotice {
                Text("\(speedNotice) WPM")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .readerGlass(in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(theme.ink.map { Color(nsColor: $0) } ?? Color.primary)
        .environment(\.colorScheme, theme.colorScheme ?? systemColorScheme)
        .onContinuousHover { phase in
            if case .active = phase { revealChrome() }
        }
        .navigationTitle(item.title)
        .navigationSubtitle("\(currentSection.title) · \(item.fractionComplete.percentString)")
        .toolbar { toolbarContent }
        .background(ReaderKeyboardHandler(
            onPlayPause: togglePlayback,
            onBack: session.back,
            onForward: session.forward,
            onFaster: { changeSpeed(by: 25) },
            onSlower: { changeSpeed(by: -25) },
            onFocus: toggleFocusMode
        ))
        .toolbar(isFocused ? .hidden : .visible, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.35), value: isFocused)
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
        .onAppear {
            session.onProgressChange = { section, word in
                library.updateProgress(for: item.id, sectionIndex: section, wordIndex: word)
            }
            session.onReadingSegment = { words, seconds in
                library.recordReading(words: words, seconds: seconds)
            }
        }
        .onDisappear {
            onFocusChange(false)
            hideTask?.cancel()
            session.pause()
            library.flushPendingChanges()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session.pause()
            library.flushPendingChanges()
        }
        .onChange(of: session.isPlaying) { _, playing in
            if playing {
                scheduleChromeHide()
            } else {
                library.flushPendingChanges()
                revealChrome()
            }
        }
        .onChange(of: showingOptions) { _, open in open ? revealChrome() : scheduleChromeHide() }
        .onChange(of: session.preferences) { _, preferences in
            library.updatePreferences(for: item.id, preferences)
        }
        .sheet(isPresented: $showingNotes) {
            NotesSheet(
                notes: item.notes,
                sectionTitle: { index in
                    item.sections.indices.contains(index) ? item.sections[index].title : item.title
                },
                noteText: $noteText,
                onAdd: {
                    library.addNote(for: item.id, text: noteText)
                    noteText = ""
                },
                onUpdate: { library.updateNote(for: item.id, noteID: $0, text: $1) },
                onDelete: { library.deleteNote(for: item.id, noteID: $0) },
                onJump: { note in
                    session.jump(toSection: note.sectionIndex, word: note.wordIndex)
                    showingNotes = false
                }
            )
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        ZStack {
            theme.background
            RadialGradient(
                colors: [Color.readerAmber.opacity(theme == .sepia ? 0.10 : 0.07), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 520
            )

            if readerMode == .rsvp {
                RSVPStage(
                    session: session,
                    hidesContext: isFocused,
                    onContinue: togglePlayback
                )
                .padding(.bottom, 110)
                .overlay(alignment: .top) {
                    if session.preferences.showSectionProgress {
                        SectionProgressBar(session: session)
                            .padding(.horizontal, 40)
                            .padding(.top, 18)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Clicking the reading area gives the reader the keyboard shortcuts.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            } else {
                FullTextReaderView(
                    sections: item.sections,
                    currentSectionIndex: session.sectionIndex,
                    currentWordIndex: session.wordIndex,
                    textColor: theme.ink ?? .labelColor,
                    appearance: theme.appearance,
                    bottomInset: 120,
                    onSelectWord: readFrom
                )
                .accessibilityIdentifier("full-text-reader")
                .overlay(alignment: .bottom) {
                    // Text fades out before it reaches the floating controls.
                    LinearGradient(
                        stops: [
                            .init(color: theme.background.opacity(0), location: 0),
                            .init(color: theme.background.opacity(0.95), location: 0.45),
                            .init(color: theme.background, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 200)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(
                get: { readerMode },
                set: { mode in
                    session.pause()
                    withAnimation(.smooth(duration: 0.25)) { readerMode = mode }
                }
            )) {
                ForEach(ReaderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .help("Reader mode")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: toggleFocusMode) {
                Label("Focus mode", systemImage: session.preferences.focusMode ? "scope" : "circle.dashed")
            }
            .help(session.preferences.focusMode
                ? "Focus mode is on: while playing, only the word and progress bar show (F)"
                : "Focus mode: while playing, hide everything except the word and progress bar (F)")

            Menu {
                ForEach(item.sections.indices, id: \.self) { index in
                    Button {
                        session.goToSection(index)
                    } label: {
                        if index == session.sectionIndex {
                            Label(item.sections[index].title, systemImage: "checkmark")
                        } else {
                            Text(item.sections[index].title)
                        }
                    }
                }
            } label: {
                Label("Sections", systemImage: "list.bullet")
            }
            .menuIndicator(.hidden)
            .help("Sections")

            Button {
                session.pause()
                showingSearch = true
            } label: {
                Label("Search in document", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("Search in document")
            .popover(isPresented: $showingSearch, arrowEdge: .bottom) {
                DocumentSearchView(sections: item.sections, query: $searchQuery) { match in
                    session.jump(toSection: match.sectionIndex, word: match.wordIndex)
                    showingSearch = false
                }
            }

            Button {
                library.toggleFavorite(item.id)
            } label: {
                Label(
                    item.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: item.isFavorite ? "star.fill" : "star"
                )
            }
            .help(item.isFavorite ? "Unfavorite" : "Favorite")

            Button {
                session.pause()
                showingNotes = true
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .help("Notes")
        }
    }

    // MARK: Behavior

    private func togglePlayback() {
        if readerMode != .rsvp {
            withAnimation(.smooth(duration: 0.25)) { readerMode = .rsvp }
        }
        session.togglePlayback()
    }

    /// Clicking a word in the text starts word-by-word reading from that word.
    private func readFrom(section: Int, word: Int) {
        session.jump(toSection: section, word: word)
        withAnimation(.smooth(duration: 0.25)) { readerMode = .rsvp }
        session.play()
    }

    private func changeSpeed(by delta: Int) {
        let speed = min(max(session.preferences.wordsPerMinute + delta, 100), 900)
        session.preferences.wordsPerMinute = speed
        withAnimation(.snappy(duration: 0.2)) { speedNotice = speed }
        speedNoticeTask?.cancel()
        speedNoticeTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { speedNotice = nil }
        }
    }

    /// Shows the controls and, during playback, hides them again after a short idle time.
    private func revealChrome() {
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.2)) { chromeVisible = true }
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        hideTask?.cancel()
        guard session.isPlaying, !controlsHovered, !showingOptions else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, session.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

// MARK: - RSVP

private struct RSVPStage: View {
    @ObservedObject var session: ReaderSession
    let hidesContext: Bool
    let onContinue: () -> Void

    var body: some View {
        if let figure = session.presentedFigure {
            FigureCard(figure: figure, onContinue: onContinue)
                .id(figure.id)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if session.isCheckingIn {
            CheckInCard(
                minutes: session.preferences.checkInMinutes,
                onContinue: {
                    NSSound(named: "Pop")?.play()
                    onContinue()
                },
                onRewind: session.rewindAfterCheckIn
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else {
            wordStage
        }
    }

    /// Changes with every word while the rhythm pulse is on and playback runs.
    private var beat: Beat? {
        guard session.preferences.rhythmPulse, session.isPlaying else { return nil }
        return Beat(index: session.displayIndex, duration: min(0.22, session.currentDisplayDuration() * 0.7))
    }

    private var wordStage: some View {
        VStack(spacing: 28) {
            ZStack {
                if session.words.isEmpty {
                    Text("This section has no readable text.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else if session.currentExpression != nil {
                    // Expressions stay on one line and shrink to fit rather than wrap.
                    Text(session.displayWords.joined(separator: " "))
                        .font(.system(size: session.preferences.fontSize * 0.8, weight: .medium, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.2)
                        .padding(.horizontal, 32)
                } else if session.displayWords.count == 1, let word = session.displayWords.first {
                    PivotWordView(word: word, fontSize: session.preferences.fontSize, beat: beat)
                } else {
                    Text(session.displayWords.joined(separator: " "))
                        .font(.system(size: max(36, session.preferences.fontSize * 0.7), weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 32)
                }
            }
            .frame(height: max(150, session.preferences.fontSize * 2.3))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rsvp-word-display")

            if session.isHoldingExpression {
                Button(action: onContinue) {
                    Label("Continue reading", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.readerAmber)
                .help("Continue reading (Space)")
            }

            if session.preferences.showContext {
                ContextLine(words: session.words, index: session.displayIndex)
                    .opacity(hidesContext ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: hidesContext)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keeps the pivot letter on the vertical center line, so the eye never moves between words.
private struct PivotWordView: View {
    let word: String
    let fontSize: Double
    let beat: Beat?

    var body: some View {
        GeometryReader { proxy in
            let split = RSVPWord(word).splitForDisplay
            let size = fittedSize(for: split, width: proxy.size.width)
            HStack(spacing: 0) {
                Text(split.prefix)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(split.pivot)
                    .foregroundStyle(Color.readerAmberText)
                    .pulse(on: beat)
                Text(split.suffix)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func fittedSize(for split: (prefix: String, pivot: String, suffix: String), width: CGFloat) -> CGFloat {
        let font = NSFont.readerRounded(size: fontSize)
        func measure(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let pivotHalf = measure(split.pivot) / 2
        let needed = max(measure(split.prefix), measure(split.suffix)) + pivotHalf
        let available = width / 2 - 28
        return needed > available ? fontSize * available / needed : fontSize
    }
}

private struct ContextLine: View {
    let words: [String]
    let index: Int

    var body: some View {
        HStack(spacing: 14) {
            Text(slice(before: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(words.indices.contains(index) ? words[index] : "")
                .foregroundStyle(Color.readerAmberText)
            Text(slice(before: false))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.body, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 40)
        .accessibilityHidden(true)
    }

    private func slice(before: Bool) -> String {
        guard !words.isEmpty else { return "" }
        if before {
            let end = min(max(index, 0), words.count)
            return words[max(0, end - 5)..<end].joined(separator: " ")
        }
        let start = min(index + 1, words.count)
        return words[start..<min(start + 5, words.count)].joined(separator: " ")
    }
}

/// One word's beat for the rhythm pulse.
private struct Beat: Equatable {
    var index: Int
    var duration: Double
}

private extension View {
    /// Brightens on each new beat and settles back to its normal colour, so the eye has a
    /// rhythm to follow. Size never changes, so letters keep their spacing.
    @ViewBuilder
    func pulse(on beat: Beat?) -> some View {
        if let beat {
            keyframeAnimator(initialValue: 0.0, trigger: beat.index) { content, flash in
                content.brightness(0.18 * flash)
            } keyframes: { _ in
                CubicKeyframe(1.0, duration: beat.duration * 0.2)
                CubicKeyframe(0.0, duration: beat.duration * 0.8)
            }
        } else {
            self
        }
    }
}

/// Pauses playback every few minutes to ask whether the reader is still following.
private struct CheckInCard: View {
    let minutes: Int
    let onContinue: () -> Void
    let onRewind: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.readerAmberText)
            Text("Still with me?")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("You've read for \(minutes) minutes. Did the last part sink in?")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: onRewind) {
                    Label("I drifted, go back", systemImage: "gobackward.30")
                }
                .controlSize(.large)
                .help("Go back about half a minute, to the start of a sentence")

                Button(action: onContinue) {
                    Label("Yes, keep going", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.readerAmber)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help("Keep reading (Space or Return)")
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("rsvp-check-in")
    }
}

/// The whole document across the top of the stage, one segment per part sized by its length,
/// filled up to the current word. It stays visible while the controls are hidden.
private struct SectionProgressBar: View {
    @ObservedObject var session: ReaderSession

    var body: some View {
        let sections = session.sections
        let counts = sections.map { max($0.wordCount, 1) }
        let total = Double(counts.reduce(0, +))
        let current = session.sectionIndex
        let fraction = min(1, Double(session.displayIndex) / Double(max(session.words.count, 1)))
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let gap: CGFloat = sections.count > 120 ? 0 : sections.count > 40 ? 1 : 3
                let available = max(0, proxy.size.width - gap * CGFloat(max(sections.count - 1, 0)))
                HStack(spacing: gap) {
                    ForEach(sections.indices, id: \.self) { index in
                        let filled = index < current ? 1 : index == current ? fraction : 0
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.secondary.opacity(index == current ? 0.3 : 0.16))
                            Rectangle().fill(Color.readerAmber)
                                .frame(width: available * Double(counts[index]) / total * filled)
                        }
                        .frame(width: available * Double(counts[index]) / total)
                        .contentShape(Rectangle())
                        .onTapGesture { session.goToSection(index) }
                        .help(sections[index].title)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
            .frame(maxWidth: 620)

            Text("\(position(current, of: sections.count)) · \(session.remainingSectionSeconds.readerDuration) left in part · \(session.remainingBookSeconds.readerDuration) in total")
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .opacity(0.8)
        }
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Part \(current + 1) of \(sections.count), \(session.remainingBookSeconds.readerDuration) left in total")
    }

    /// "Part 2 of 5", with the section's own title when it has one.
    private func position(_ index: Int, of count: Int) -> String {
        let title = session.currentSection?.title ?? ""
        let part = "Part \(index + 1) of \(count)"
        return title.isEmpty || title == "Part \(index + 1)" ? part : "\(part) · \(title)"
    }
}

// MARK: - Controls

private struct ReaderControls: View {
    @ObservedObject var session: ReaderSession
    @Binding var showingOptions: Bool
    let onPlayPause: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button(action: session.back) {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Back")
                .accessibilityLabel("Back")

                Button(action: onPlayPause) {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayButtonStyle())
                .padding(.horizontal, 4)
                .help(session.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

                Button(action: session.forward) {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Forward")
                .accessibilityLabel("Forward")
            }

            Slider(value: progress, in: 0...Double(max(session.maxWordIndex, 1)))
                .controlSize(.small)
                .tint(.readerAmber)
                .frame(minWidth: 90, maxWidth: 360)
                .disabled(session.maxWordIndex <= 0)
                .accessibilityLabel("Position in section")
                .accessibilityIdentifier("progress-slider")

            SpeedControl(wordsPerMinute: $session.preferences.wordsPerMinute)

            Button {
                showingOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Reading options")
            .accessibilityLabel("Reading options")
            .popover(isPresented: $showingOptions, arrowEdge: .top) {
                ReadingOptionsView(preferences: $session.preferences)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .readerGlass(in: Capsule())
        .frame(maxWidth: 640)
    }

    private var progress: Binding<Double> {
        Binding(
            get: { Double(session.displayIndex) },
            set: { session.setWordIndex(Int($0.rounded())) }
        )
    }
}

private struct SpeedControl: View {
    @Binding var wordsPerMinute: Int

    var body: some View {
        HStack(spacing: 0) {
            Button { wordsPerMinute = max(100, wordsPerMinute - 25) } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(GlassIconButtonStyle(size: 26))
            .help("Slower")
            .accessibilityLabel("Slower")

            VStack(spacing: -2) {
                Text("\(wordsPerMinute)")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(wordsPerMinute)))
                Text("WPM")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(wordsPerMinute) words per minute")

            Button { wordsPerMinute = min(900, wordsPerMinute + 25) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(GlassIconButtonStyle(size: 26))
            .help("Faster")
            .accessibilityLabel("Faster")
        }
        .animation(.snappy(duration: 0.2), value: wordsPerMinute)
        .help("Speed. Up and Down arrows change it while reading.")
    }
}

private struct RemainingTimeLabel: View {
    @ObservedObject var session: ReaderSession

    var body: some View {
        Text("\(session.remainingSectionSeconds.readerDuration) left in section · \(session.remainingBookSeconds.readerDuration) in book")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .help("Estimated time remaining at the selected speed, before optional pauses.")
    }
}

extension NSFont {
    static func readerRounded(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
