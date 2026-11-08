import SwiftUI
import JellyCore

/// S08: full-screen player. Same controls whichever engine is playing.
struct PlayerView: View {
    let request: PlayRequest
    /// What is playing now: the next episode replaces the first one.
    private var item: BaseItem { model?.item ?? request.item }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: PlayerModel?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var landscapeLocked = Prefs.landscapeLock

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine = model?.engine {
                EngineHost(engineView: engine.view)
                    .ignoresSafeArea()
            }

            // Tap anywhere to show or hide the controls.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if let model {
                statusLayer(model)
                if let left = model.upNextCountdown, let next = model.upNext {
                    UpNextCard(next: next, secondsLeft: left, api: app.api,
                               play: { model.playUpNextNow() },
                               dismiss: { model.dismissUpNext() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, Theme.Space.l)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.Colors.scrim)
                        .clipShape(Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 90)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if controlsVisible || !model.isPlaying {
                    controls(model)
                        .transition(.opacity)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .task {
            guard model == nil, let api = app.api else { return }
            // Back from Picture in Picture: the same film, still running.
            let m = app.player(for: request, api: api)
            model = m
            UIApplication.shared.isIdleTimerDisabled = true
            if landscapeLocked { Orientation.lockLandscape() }
            scheduleHide()
            await m.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model?.enterBackground() }
        }
        .onChange(of: model?.phase) { _, phase in
            if phase == .ended { close() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if landscapeLocked { Orientation.unlock(backToPortrait: true) }
            // In PiP the film goes on without this screen.
            if model?.isPiPActive != true { model?.close() }
        }
    }

    // MARK: Layers

    @ViewBuilder
    private func statusLayer(_ model: PlayerModel) -> some View {
        switch model.phase {
        case .preparing, .buffering, .reconnecting:
            VStack(spacing: Theme.Space.m) {
                ProgressView().tint(.white).scaleEffect(1.4)
                Text(statusText(model))
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .animation(.default, value: model.openingMessage)
            }
            .padding(Theme.Space.l)
            .background(Theme.Colors.scrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .allowsHitTesting(false)
        case .failed(let message):
            VStack(spacing: Theme.Space.l) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Colors.danger)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                HStack(spacing: Theme.Space.m) {
                    Button("Riprova") { model.retry() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Chiudi") { close() }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 320)
            }
            .padding(Theme.Space.xl)
            .background(Theme.Colors.scrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        default:
            EmptyView()
        }
    }

    private func controls(_ model: PlayerModel) -> some View {
        VStack {
            // Top: close, title, engine
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: Theme.Size.playerButton, height: Theme.Size.playerButton)
                }
                .accessibilityLabel("Chiudi")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if let sub = item.displaySubtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button { toggleLandscapeLock() } label: {
                    Image(systemName: landscapeLocked ? "lock.rotation" : "lock.open.rotation")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(landscapeLocked ? Theme.Colors.accent : .white)
                        .frame(width: Theme.Size.playerButton, height: Theme.Size.playerButton)
                }
                .accessibilityLabel(landscapeLocked ? "Sblocca rotazione" : "Blocca in orizzontale")
                if model.canPiP {
                    Button {
                        model.requestPiP()
                        scheduleHide()
                    } label: {
                        Image(systemName: model.isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.title3.weight(.semibold))
                            .frame(width: Theme.Size.playerButton, height: Theme.Size.playerButton)
                    }
                    .accessibilityLabel("Picture in Picture")
                }
                if !model.audioOptions.isEmpty || !model.subtitleOptions.isEmpty {
                    tracksMenu(model)
                }
                if !model.routeLabel.isEmpty {
                    Text(routeBadge(model))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .background(.white.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            Spacer()

            // Middle: back 10, play/pause, forward 10
            HStack(spacing: Theme.Space.xxl * 1.5) {
                roundButton("gobackward.10", size: Theme.Size.playerButton, label: "Indietro di 10 secondi") {
                    model.skip(-10)
                }
                roundButton(model.isPlaying ? "pause.fill" : "play.fill",
                            size: Theme.Size.playerMainButton,
                            label: model.isPlaying ? "Pausa" : "Riproduci") {
                    model.togglePlay()
                }
                roundButton("goforward.10", size: Theme.Size.playerButton, label: "Avanti di 10 secondi") {
                    model.skip(10)
                }
            }
            .opacity(isFailed(model) ? 0 : 1)

            Spacer()

            // Bottom: time and scrubber
            VStack(spacing: Theme.Space.xs) {
                Slider(
                    value: Binding(
                        get: { scrubbing ?? model.position },
                        set: { scrubbing = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            hideTask?.cancel()
                        } else {
                            if let target = scrubbing { model.seek(to: target) }
                            scrubbing = nil
                            scheduleHide()
                        }
                    }
                )
                .tint(Theme.Colors.accent)
                .accessibilityLabel("Posizione")

                HStack {
                    Text(Ticks.clock(scrubbing ?? model.position))
                    Spacer()
                    Text("-" + Ticks.clock(max(model.duration - (scrubbing ?? model.position), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Space.l)
        .background(
            LinearGradient(colors: [Theme.Colors.scrim, .clear, .clear, Theme.Colors.scrim],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func roundButton(_ symbol: String, size: CGFloat, label: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private func tracksMenu(_ model: PlayerModel) -> some View {
        Menu {
            if model.audioOptions.count > 1 {
                Section("Audio") {
                    ForEach(model.audioOptions) { t in
                        Button { model.selectAudio(t.id) } label: {
                            if t.id == model.currentAudio { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                }
            }
            Section("Sottotitoli") {
                Button { model.selectSubtitle(nil) } label: {
                    if model.currentSubtitle == nil { Label("Nessuno", systemImage: "checkmark") } else { Text("Nessuno") }
                }
                ForEach(model.subtitleOptions) { t in
                    Button { model.selectSubtitle(t.id) } label: {
                        if t.id == model.currentSubtitle { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title3.weight(.semibold))
                .frame(width: Theme.Size.playerButton, height: Theme.Size.playerButton)
        }
        .accessibilityLabel("Audio e sottotitoli")
    }

    private func statusText(_ model: PlayerModel) -> String {
        switch model.phase {
        case .preparing: return model.openingMessage
        case .reconnecting: return "Riconnessione…"
        default: return "Caricamento…"
        }
    }

    private func routeBadge(_ model: PlayerModel) -> String {
        guard let s = model.openSeconds else { return model.routeLabel }
        return "\(model.routeLabel) · " + String(format: "%.1f s", s)
    }

    private func isFailed(_ model: PlayerModel) -> Bool {
        if case .failed = model.phase { return true }
        return false
    }

    // MARK: Behaviour

    /// Lock: turns the screen to landscape and keeps it there, even if the phone
    /// is held upright. Unlock: the screen follows the phone again.
    private func toggleLandscapeLock() {
        landscapeLocked.toggle()
        Prefs.landscapeLock = landscapeLocked
        if landscapeLocked {
            Orientation.lockLandscape()
        } else {
            Orientation.unlock(backToPortrait: false)
        }
        scheduleHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, scrubbing == nil, model?.isPlaying == true else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func close() {
        model?.close()
        dismiss()
    }
}

/// Hosts the engine's UIView (AVPlayerLayer or VLC drawable) inside SwiftUI.
struct EngineHost: UIViewRepresentable {
    let engineView: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        guard engineView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        engineView.frame = container.bounds
        engineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(engineView)
    }
}

/// "Next episode" card, bottom right, in the last 30 seconds. Starts by itself
/// at zero; X keeps watching the credits.
struct UpNextCard: View {
    let next: BaseItem
    let secondsLeft: Int
    let api: JellyfinAPI?
    let play: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button(action: play) {
                HStack(spacing: Theme.Space.m) {
                    ZStack {
                        RemoteImage(url: next.landscapeImageURL(api: api, width: 240))
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prossimo episodio tra \(secondsLeft) s")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Colors.accent)
                        Text([next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: 170, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Guarda il prossimo episodio")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Resta su questo episodio")
        }
        .padding(Theme.Space.m)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}
