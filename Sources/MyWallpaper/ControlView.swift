import SwiftUI

struct ControlView: View {
    @ObservedObject var model: WallpaperModel
    var onOpenSettings: () -> Void = {}
    @State private var dropTargeted = false
    private let accent = Color(red: 0.48, green: 0.86, blue: 0.73)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            preview
            if let error = model.errorMessage { errorBanner(error) }
            controls
            HStack(spacing: 7) {
                Image(systemName: "menubar.rectangle")
                Text("Обои работают и с закрытым окном. Параметры — в меню → Настройки.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding(28)
        .frame(minWidth: 720, idealWidth: 800, maxWidth: .infinity,
               minHeight: 496, idealHeight: 536, maxHeight: .infinity)
        .background(Color(red: 0.065, green: 0.075, blue: 0.085))
        .preferredColorScheme(.dark)
        .tint(accent)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            model.selectVideo(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("MyWallpaper").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Твой рабочий стол. В движении.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.isPlaying ? accent : .secondary).frame(width: 6, height: 6)
                Text(model.isPlaying ? "LIVE" : "LOCAL")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(.white.opacity(0.05), in: Capsule())
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("Настройки")
            .accessibilityLabel("Открыть настройки")
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = model.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: model.scaling == .fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(.black)
                } else {
                    LandscapePlaceholder()
                    if model.selectedURL == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(accent)
                            Text("Добавь немного жизни")
                                .font(.system(size: 24, weight: .medium, design: .rounded))
                            Text("Перетащи видео сюда или выбери файл")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            Button("Выбрать видео…", action: model.chooseVideo)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .padding(.top, 4)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 14)
                    }
                }
                if model.selectedURL != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ТЕКУЩИЕ ОБОИ")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .tracking(2).foregroundStyle(.white.opacity(0.65))
                                Text(model.selectedURL?.deletingPathExtension().lastPathComponent ?? "Видео")
                                    .font(.system(size: 17, weight: .medium))
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            Spacer(minLength: 18)
                            Button(action: model.revealVideo) {
                                Image(systemName: "folder").font(.system(size: 15))
                            }
                            .buttonStyle(.bordered)
                            .help("Показать видео в Finder")
                            .accessibilityLabel("Показать видео в Finder")
                        }
                        .padding(22)
                    }
                }
                if model.isLoading {
                    Color.black.opacity(0.35)
                    ProgressView("Открываем видео…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(accent.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        }
                        .overlay(alignment: .top) {
                            Text("Отпусти, чтобы установить обои")
                                .font(.system(size: 13, weight: .medium))
                                .padding(12)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(20)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)) }
        }
        .frame(minHeight: 230, idealHeight: 300, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Предпросмотр обоев")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.status).font(.system(size: 13, weight: .medium))
                Text(model.hasWallpaper ? "Зациклено · \(model.isMuted ? "без звука" : "со звуком")" : "MP4, MOV и другие видео macOS")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button(action: model.chooseVideo) {
                Label("Выбрать…", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
            Button(action: model.togglePlayback) {
                Label(model.hasWallpaper && !model.userPaused ? "Пауза" : "Включить",
                      systemImage: model.hasWallpaper && !model.userPaused ? "pause.fill" : "play.fill")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLoading || model.selectedURL == nil)
            Button(action: model.stop) { Image(systemName: "stop.fill") }
                .controlSize(.large)
                .disabled(!model.hasWallpaper && !model.isLoading)
                .help("Выключить обои и вернуть обычный рабочий стол")
                .accessibilityLabel("Выключить обои")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Закрыть сообщение")
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LandscapePlaceholder: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.17, blue: 0.19), Color(red: 0.06, green: 0.1, blue: 0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color(red: 0.45, green: 0.8, blue: 0.65).opacity(0.06))
                    .frame(width: 240, height: 240).blur(radius: 35)
                    .offset(x: geometry.size.width * 0.28, y: -60)
                ridge(size: geometry.size, points: [0.70, 0.45, 0.60, 0.28, 0.58, 0.40, 0.65])
                    .fill(Color(red: 0.14, green: 0.27, blue: 0.26).opacity(0.45))
                ridge(size: geometry.size, points: [0.85, 0.72, 0.88, 0.62, 0.78, 0.55, 0.80])
                    .fill(Color(red: 0.05, green: 0.12, blue: 0.14).opacity(0.8))
            }
        }
        .accessibilityHidden(true)
    }

    private func ridge(size: CGSize, points: [CGFloat]) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, height) in points.enumerated() {
                path.addLine(to: CGPoint(x: size.width * CGFloat(index) / CGFloat(points.count - 1), y: size.height * height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}
