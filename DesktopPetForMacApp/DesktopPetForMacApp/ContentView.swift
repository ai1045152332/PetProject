// ContentView.swift

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject var viewModel: PetViewModel
    
    init(viewModel: PetViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    var body: some View {
        ZStack {
            CatImageContainer(viewModel: viewModel)
                .frame(width: 160, height: 160)
            
            if viewModel.showContextMenu {
                contextMenu
                    .transition(.scale.combined(with: .opacity))
                    .position(x: viewModel.menuLocation.x, y: viewModel.menuLocation.y - 20)
            }
        }
        .frame(width: 160, height: 160)
        .background(Color.clear)
    }
    
    private var contextMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuButton(title: "喂食 🐟", action: { viewModel.feed() })
            Divider()
            if viewModel.animationState == .sleep {
                menuButton(title: "叫醒 ⏰", action: { viewModel.wakeUp() })
            } else {
                menuButton(title: "睡觉 💤", action: { viewModel.sleep() })
            }
            Divider()
            menuButton(title: "关闭 ❌", action: { viewModel.quit() })
        }
        .frame(width: 120)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func menuButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        .background(Color.clear.contentShape(Rectangle()))
    }
}

// MARK: - NSImageView Bridge

struct CatImageContainer: NSViewRepresentable {
    @ObservedObject var viewModel: PetViewModel
    
    func makeNSView(context: Context) -> CatImageNSView {
        let view = CatImageNSView()
        view.viewModel = viewModel
        return view
    }
    
    func updateNSView(_ nsView: CatImageNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.updateImage()
    }
}

class CatImageNSView: NSView {
    weak var viewModel: PetViewModel?
    private let imageView = NSImageView()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = bounds
        imageView.wantsLayer = true
        addSubview(imageView)
    }
    
    func updateImage() {
        guard let vm = viewModel else { return }
        
        if let image = vm.currentFrameImage {
            imageView.image = image
            imageView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            // 🔴 调试红色：图片加载失败
            imageView.image = nil
            imageView.layer?.backgroundColor = NSColor.red.cgColor
        }
        
        if vm.facing == .left {
            imageView.layer?.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        } else {
            imageView.layer?.setAffineTransform(.identity)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        viewModel?.handleLeftClick()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        viewModel?.handleRightClick(at: CGPoint(x: point.x, y: point.y))
    }
    
    override var acceptsFirstResponder: Bool { true }
}
