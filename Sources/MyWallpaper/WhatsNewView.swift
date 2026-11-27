import SwiftUI

@MainActor
struct WhatsNewView: View {
    let release: WhatsNewRelease
    var localizer: AppLocalizer = .english
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 58, height: 58)
                                .background(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading,
                                                           endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 17))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(localizer.text("Что нового"))
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                Text("MyWallpaper \(release.version)")
                                    .font(.system(size: 22, weight: .bold))
                            }
                        }
                        Text(localizer.text(release.titleKey))
                            .font(.system(size: 25, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(localizer.text(release.subtitleKey))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(release.features) { feature in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: feature.symbol)
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundStyle(.teal)
                                    .frame(width: 30, height: 30)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(localizer.text(feature.titleKey))
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(localizer.text(feature.detailKey))
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(28)
            }
            Divider()
            HStack(alignment: .center, spacing: 20) {
                Text(localizer.text("Это окно можно снова открыть в разделе «Обновления»."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(localizer.text("Готово"), action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 490, idealHeight: 570)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
