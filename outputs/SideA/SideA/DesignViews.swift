import SwiftUI
import UIKit

enum Ink {
    private static func adaptive(_ day: (CGFloat, CGFloat, CGFloat), _ night: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? night : day
            return UIColor(red:rgb.0, green:rgb.1, blue:rgb.2, alpha:1)
        })
    }
    static let paper = adaptive((0.978,0.967,0.941),(0.092,0.106,0.10))
    static let dark = adaptive((0.11,0.16,0.145),(0.92,0.94,0.90))
    static let teal = adaptive((0.18,0.31,0.275),(0.69,0.84,0.75))
    static let quiet = adaptive((0.35,0.395,0.36),(0.71,0.75,0.70))
    static let rose = adaptive((0.67,0.25,0.28),(0.98,0.66,0.67))
    static let cream = Color(red:0.978,green:0.967,blue:0.941)
    static let forest = Color(red:0.18,green:0.31,blue:0.275)
    static let well = adaptive((0.88,0.88,0.80),(0.20,0.25,0.22))
    static let warm = Color(red: 0.82, green: 0.64, blue: 0.54)
    static func title(_ size: CGFloat) -> Font { .custom("Songti SC", size: size).weight(.semibold) }
    static func side(_ size: CGFloat) -> Font { .custom("Baskerville-Italic", size: size) }
}

struct Paper: View {
    var body: some View {
        ZStack {
            Ink.paper
            LinearGradient(colors: [Ink.well.opacity(0.42), Ink.paper.opacity(0)], startPoint: .topTrailing, endPoint: .center)
        }.ignoresSafeArea()
    }
}

struct GlassPlate: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 0.7).allowsHitTesting(false) }
    }
}
extension View {
    func glassPlate(_ radius: CGFloat) -> some View { modifier(GlassPlate(radius: radius)) }
}

@MainActor private enum SleeveImages {
    private static let bundled = NSCache<NSURL, UIImage>()
    static func shipped(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        if let image = bundled.object(forKey: url as NSURL) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        bundled.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct ArtView: View {
    var track: Track?
    var embedded: Data? = nil
    @State private var remoteImage: UIImage?
    @State private var loadedID: String?
    @State private var embeddedImage: UIImage?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Ink.warm, Ink.forest], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = (embedded == nil ? nil : embeddedImage) ?? SleeveImages.shipped(track?.localArtworkURL) ?? (loadedID == track?.id ? remoteImage : nil) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: max(14, min(geo.size.width, geo.size.height) * 0.26), weight: .thin)).foregroundStyle(.white.opacity(0.72))
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .accessibilityHidden(true)
        .onChange(of: embedded, initial: true) { _, data in embeddedImage = data.flatMap(UIImage.init(data:)) }
        .task(id: track?.id) {
            guard let track, track.localArtworkURL == nil, embedded == nil else { return }
            let data = await GDClient.shared.coverData(track)
            guard !Task.isCancelled else { return }
            remoteImage = data.flatMap(UIImage.init(data:))
            loadedID = track.id
        }
    }

}

struct Vinyl: View {
    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.black, .gray.opacity(0.8), .black, Color(white: 0.19), .black, Color(white: 0.39), .black], center: .center))
            Canvas { context, size in
                let step = max(2.0, size.width / 60)
                var inset = step
                while inset < size.width * 0.34 {
                    let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                    context.stroke(Path(ellipseIn: box), with: .color(.white.opacity(0.14)), lineWidth: 0.55)
                    inset += step
                }
            }
            Circle().fill(Ink.warm).scaleEffect(0.32)
            Circle().fill(.black).scaleEffect(0.032)
        }.accessibilityHidden(true)
    }
}

struct Sleeve: View {
    let track: Track?
    var embedded: Data? = nil
    var tilt: Double = 0
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width / 1.24, geo.size.height)
            ZStack(alignment: .leading) {
                Vinyl().frame(width: side * 0.97, height: side * 0.97).offset(x: side * 0.27)
                ArtView(track: track, embedded: embedded).frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.25), lineWidth: 0.7) }
            }.frame(width: side * 1.24, height: side, alignment: .leading).rotationEffect(.degrees(tilt))
                .shadow(color: .black.opacity(0.25), radius: side * 0.045, x: 1, y: side * 0.04)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct FeatureCard: View {
    let title: String
    let subtitle: String
    let side: String
    let caption: String
    let track: Track?
    let open: () -> Void
    let play: () -> Void
    var playable = true
    var body: some View {
        ZStack {
            ArtView(track: track).scaleEffect(1.35).blur(radius: 22).saturation(0.79)
            LinearGradient(colors: [.white.opacity(0.65), .clear, Ink.forest.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(side).font(Ink.side(32)).accessibilityHidden(true)
                        Text(caption).font(.caption2.weight(.semibold)).tracking(1.0)
                    }.foregroundStyle(Ink.forest)
                    Spacer()
                    Sleeve(track: track, tilt: -9).frame(width: 158, height: 128).padding(.trailing, 8)
                }.padding(.horizontal, 17).padding(.top, 16)
                Spacer(minLength: 2)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(Ink.title(29)).lineLimit(1)
                        Text(subtitle).font(.caption.weight(.medium)).lineLimit(1)
                    }.foregroundStyle(Ink.dark)
                    Spacer()
                    Button(action: play) {
                        Image(systemName: "play.fill").font(.system(size: 15)).foregroundStyle(Ink.forest).frame(width: 42, height: 42).background(.white.opacity(0.73), in: Circle())
                    }.buttonStyle(.plain).disabled(!playable).accessibilityLabel("播放" + title)
                }.padding(.horizontal, 18).padding(.vertical, 13)
                    .background(.thinMaterial).overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.7)).frame(height: 0.7) }
            }
        }.frame(height: 224).clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 0.7).allowsHitTesting(false) }
            .contentShape(Rectangle()).onTapGesture(perform: open)
            .accessibilityAction(named: "查看歌单", open)
    }
}

struct SectionTitle: View {
    var title: String
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.bold()).foregroundStyle(Ink.dark)
            if let note { Text(note).font(.caption).foregroundStyle(Ink.quiet) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyHint: View {
    var symbol = "music.quarternote.3"
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(Ink.teal)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(Ink.quiet).multilineTextAlignment(.center)
        }.padding(.vertical, 30).frame(maxWidth: .infinity)
    }
}

struct CollectionSleeve: View {
    let title: String
    let note: String
    let tracks: [Track]
    let fallback: Track?
    var selectedCover: Track?
    private var cover: Track? { selectedCover ?? tracks.first ?? fallback }
    private var secondCover: Track? { tracks.first { $0.id != cover?.id } }
    var body: some View {
        ZStack {
            ArtView(track: cover).scaleEffect(1.3).blur(radius: 18).saturation(0.82)
            LinearGradient(colors:[.white.opacity(0.5),Ink.warm.opacity(0.25),Ink.forest.opacity(0.15)],startPoint:.topLeading,endPoint:.bottomTrailing)
            VStack(spacing:0) {
                HStack(alignment:.top) {
                    Text("Side A").font(Ink.side(27)).foregroundStyle(Ink.forest)
                    Spacer()
                    ZStack {
                        if let secondCover {
                            ArtView(track:secondCover).frame(width:87,height:87).rotationEffect(.degrees(-14)).offset(x:-28,y:4)
                        }
                        ArtView(track:cover).frame(width:93,height:93).rotationEffect(.degrees(5))
                    }.shadow(color:.black.opacity(0.19),radius:4,y:3).padding(.trailing,6)
                }.padding(.horizontal,18).padding(.top,14)
                Spacer(minLength:8)
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text(title).font(Ink.title(27)).lineLimit(1)
                        Text(note).font(.caption.weight(.medium)).lineLimit(2)
                    }
                    Spacer(); Text("33⅓").font(Ink.side(24)).opacity(0.65).accessibilityHidden(true)
                }.foregroundStyle(Ink.dark).padding(.horizontal,18).padding(.vertical,12)
                    .background(.thinMaterial).overlay(alignment:.top) { Rectangle().fill(.white.opacity(0.72)).frame(height:0.7) }
            }
        }.frame(height:200).clipShape(RoundedRectangle(cornerRadius:21,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:21).strokeBorder(.white.opacity(0.58),lineWidth:0.7) }
    }
}
