import SwiftUI
import JellyCore

/// S08: full-screen player. Same controls whichever engine is playing.
struct PlayerView: View {
    let item: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: PlayerModel?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?

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
            let m = PlayerModel(item: item, api: api, sync: app.progress, preference: app.playerPreference)
            model = m
            UIApplication.shared.isIdleTimerDisabled = true
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
            model?.close()
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
