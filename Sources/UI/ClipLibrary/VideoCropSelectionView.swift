import SwiftUI

enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free
    case widescreen
    case square
    case standard
    case portrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .widescreen: return "16:9"
        case .square: return "1:1"
        case .standard: return "4:3"
        case .portrait: return "9:16"
        }
    }

    private var aspectRatio: CGFloat? {
        switch self {
        case .free: return nil
        case .widescreen: return 16 / 9
        case .square: return 1
        case .standard: return 4 / 3
        case .portrait: return 9 / 16
        }
    }

    func cropRect(for videoSize: CGSize) -> CGRect {
        guard let aspectRatio, videoSize.width > 0, videoSize.height > 0 else {
            return NormalizedVideoCrop.fullFrame.rect
        }

        let videoAspect = videoSize.width / videoSize.height
        if aspectRatio >= videoAspect {
            let height = videoAspect / aspectRatio
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }

        let width = aspectRatio / videoAspect
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
}

enum VideoCropSelectionMath {
    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private enum CropHandle: CaseIterable, Identifiable {
    case topLeading
    case top
    case topTrailing
    case leading
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: String { String(describing: self) }

    var unitPoint: UnitPoint {
        switch self {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .leading: return .leading
        case .trailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

struct VideoCropSelectionView: View {
    @Binding var selection: CGRect
    let videoSize: CGSize
    var onManualChange: () -> Void

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let videoRect = VideoCropSelectionMath.aspectFitRect(contentSize: videoSize, in: bounds)
            let cropRect = displayRect(for: selection, in: videoRect)

            ZStack(alignment: .topLeading) {
                shade(CGRect(x: videoRect.minX, y: videoRect.minY, width: videoRect.width, height: max(0, cropRect.minY - videoRect.minY)))
                shade(CGRect(x: videoRect.minX, y: cropRect.maxY, width: videoRect.width, height: max(0, videoRect.maxY - cropRect.maxY)))
                shade(CGRect(x: videoRect.minX, y: cropRect.minY, width: max(0, cropRect.minX - videoRect.minX), height: cropRect.height))
                shade(CGRect(x: cropRect.maxX, y: cropRect.minY, width: max(0, videoRect.maxX - cropRect.maxX), height: cropRect.height))

                Rectangle()
                    .stroke(Color.clear, lineWidth: 14)
                    .contentShape(Rectangle().stroke(lineWidth: 18))
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .gesture(moveGesture(in: videoRect))

                Rectangle()
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .allowsHitTesting(false)

                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.72))
                    Circle()
                        .stroke(AppTheme.accent, lineWidth: 2)
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 38, height: 38)
                .contentShape(Circle().inset(by: -8))
                .position(x: cropRect.midX, y: cropRect.midY)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                .gesture(moveGesture(in: videoRect))
                .help("Drag to move the crop area")
                .accessibilityLabel("Move crop area")

                ForEach(CropHandle.allCases) { handle in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(AppTheme.accent, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .contentShape(Rectangle().inset(by: -7))
                        .gesture(resizeGesture(handle: handle, in: videoRect))
                        .position(position(for: handle, in: cropRect))
                        .accessibilityLabel("Crop \(handle.id) handle")
                }
            }
            .clipped()
            .coordinateSpace(name: Self.overlaySpace)
        }
    }

    private static let overlaySpace = "cropOverlay"

    private func shade(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.58))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func displayRect(for normalized: CGRect, in videoRect: CGRect) -> CGRect {
        CGRect(
            x: videoRect.minX + normalized.minX * videoRect.width,
            y: videoRect.minY + normalized.minY * videoRect.height,
            width: normalized.width * videoRect.width,
            height: normalized.height * videoRect.height
        )
    }

    private func position(for handle: CropHandle, in rect: CGRect) -> CGPoint {
        let inset: CGFloat = 7
        let x: CGFloat
        switch handle.unitPoint.x {
        case 0: x = rect.minX + inset
        case 1: x = rect.maxX - inset
        default: x = rect.midX
        }
        let y: CGFloat
        switch handle.unitPoint.y {
        case 0: y = rect.minY + inset
        case 1: y = rect.maxY - inset
        default: y = rect.midY
        }
        return CGPoint(
            x: x,
            y: y
        )
    }

    private func moveGesture(in videoRect: CGRect) -> some Gesture {
        // Track the drag in the overlay's coordinate space: the handles move
        // with the selection, so a .local-space translation would oscillate.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.overlaySpace))
            .onChanged { value in
                guard videoRect.width > 0, videoRect.height > 0 else { return }
                if dragStart == nil {
                    dragStart = selection
                    onManualChange()
                }
                guard let start = dragStart else { return }
                let dx = value.translation.width / videoRect.width
                let dy = value.translation.height / videoRect.height
                selection.origin.x = min(max(0, start.minX + dx), 1 - start.width)
                selection.origin.y = min(max(0, start.minY + dy), 1 - start.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(handle: CropHandle, in videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.overlaySpace))
            .onChanged { value in
                guard videoRect.width > 0, videoRect.height > 0 else { return }
                if dragStart == nil {
                    dragStart = selection
                    onManualChange()
                }
                guard let start = dragStart else { return }
                let dx = value.translation.width / videoRect.width
                let dy = value.translation.height / videoRect.height
                let minWidth = min(0.25, 48 / videoRect.width)
                let minHeight = min(0.25, 48 / videoRect.height)

                var minX = start.minX
                var maxX = start.maxX
                var minY = start.minY
                var maxY = start.maxY

                switch handle {
                case .topLeading, .leading, .bottomLeading:
                    minX = min(max(0, start.minX + dx), maxX - minWidth)
                case .topTrailing, .trailing, .bottomTrailing:
                    maxX = max(min(1, start.maxX + dx), minX + minWidth)
                case .top, .bottom:
                    break
                }

                switch handle {
                case .topLeading, .top, .topTrailing:
                    minY = min(max(0, start.minY + dy), maxY - minHeight)
                case .bottomLeading, .bottom, .bottomTrailing:
                    maxY = max(min(1, start.maxY + dy), minY + minHeight)
                case .leading, .trailing:
                    break
                }

                selection = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }
}
