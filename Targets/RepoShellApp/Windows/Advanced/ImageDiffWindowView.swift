import SwiftUI
import Cocoa
import CoreImage

enum ImageCompareMode: String, CaseIterable {
    case sideBySide
    case splitSwipe
    case onionSkin
    case difference
}

struct ImageDiffWindowView: View {
    let leftPath: String
    let rightPath: String
    let leftTitle: String
    let rightTitle: String

    @State private var mode: ImageCompareMode = .sideBySide
    @State private var swipePosition: Double = 0.5
    @State private var onionOpacity: Double = 0.5
    @State private var zoom: Double = 1.0
    @State private var checkerboardBg: Bool = true

    @State private var leftImage: NSImage?
    @State private var rightImage: NSImage?
    @State private var diffImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Picker("", selection: $mode) {
                    Text(L("Side by Side", "并排对比")).tag(ImageCompareMode.sideBySide)
                    Text(L("Split Swipe", "滑动分屏")).tag(ImageCompareMode.splitSwipe)
                    Text(L("Onion Skin", "透明度叠加")).tag(ImageCompareMode.onionSkin)
                    Text(L("Difference", "像素差值")).tag(ImageCompareMode.difference)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                if mode == .splitSwipe {
                    Slider(value: $swipePosition, in: 0...1)
                        .frame(width: 120)
                } else if mode == .onionSkin {
                    Slider(value: $onionOpacity, in: 0...1)
                        .frame(width: 120)
                }

                Toggle(L("Grid", "网格"), isOn: $checkerboardBg)

                HStack(spacing: 4) {
                    Button("-") { zoom = max(0.2, zoom - 0.25) }
                    Text("\(Int(zoom * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44)
                    Button("+") { zoom = min(4.0, zoom + 0.25) }
                    Button("1:1") { zoom = 1.0 }
                }
            }
            .padding()

            Divider()

            GeometryReader { geo in
                ZStack {
                    if checkerboardBg {
                        Color.gray.opacity(0.15)
                    } else {
                        Color.black.opacity(0.85)
                    }

                    switch mode {
                    case .sideBySide:
                        HStack(spacing: 12) {
                            imageCard(image: leftImage, title: leftTitle, path: leftPath, maxWidth: geo.size.width / 2 - 20, maxHeight: geo.size.height - 40)
                            imageCard(image: rightImage, title: rightTitle, path: rightPath, maxWidth: geo.size.width / 2 - 20, maxHeight: geo.size.height - 40)
                        }
                        .padding()

                    case .splitSwipe:
                        ZStack {
                            if let l = leftImage {
                                Image(nsImage: l)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .scaleEffect(zoom)
                            }
                            if let r = rightImage {
                                Image(nsImage: r)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .scaleEffect(zoom)
                                    .mask(
                                        GeometryReader { maskGeo in
                                            HStack(spacing: 0) {
                                                Color.clear.frame(width: maskGeo.size.width * swipePosition)
                                                Color.black
                                            }
                                        }
                                    )
                            }
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: 2)
                                .position(x: geo.size.width * swipePosition, y: geo.size.height / 2)
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            swipePosition = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                        })

                    case .onionSkin:
                        ZStack {
                            if let l = leftImage {
                                Image(nsImage: l)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .scaleEffect(zoom)
                            }
                            if let r = rightImage {
                                Image(nsImage: r)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .scaleEffect(zoom)
                                    .opacity(onionOpacity)
                            }
                        }

                    case .difference:
                        if let diff = diffImage {
                            Image(nsImage: diff)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .scaleEffect(zoom)
                        } else {
                            EmptyStateBox(systemImage: "photo", title: L("Unable to Compute Difference", "无法生成像素差值图"))
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadImages)
    }

    @ViewBuilder
    private func imageCard(image: NSImage?, title: String, path: String, maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            if let img = image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: min(maxWidth, img.size.width * zoom), height: min(maxHeight - 40, img.size.height * zoom))
                }
                Text("\(Int(img.size.width)) × \(Int(img.size.height)) px")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(L("Missing Image", "无图片"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadImages() {
        leftImage = NSImage(contentsOfFile: leftPath)
        rightImage = NSImage(contentsOfFile: rightPath)
        if let l = leftImage, let r = rightImage {
            diffImage = computeDifferenceImage(left: l, right: r)
        }
    }

    private func computeDifferenceImage(left: NSImage, right: NSImage) -> NSImage? {
        guard let leftData = left.tiffRepresentation,
              let rightData = right.tiffRepresentation,
              let ciLeft = CIImage(data: leftData),
              let ciRight = CIImage(data: rightData),
              let filter = CIFilter(name: "CIDifferenceBlendMode") else {
            return nil
        }
        filter.setValue(ciLeft, forKey: kCIInputImageKey)
        filter.setValue(ciRight, forKey: kCIInputBackgroundImageKey)
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
