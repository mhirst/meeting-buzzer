import AppKit
import EventKit
import SwiftUI

class OverlayWindowController: NSObject {
    var windows: [NSWindow] = []
    var onDismiss: (() -> Void)?
    private var isClosed = false

    init(event: EKEvent, videoLink: URL?, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init()

        for screen in NSScreen.screens {
            let window = createOverlayWindow(on: screen, event: event, videoLink: videoLink)
            windows.append(window)
        }
    }

    private func createOverlayWindow(on screen: NSScreen, event: EKEvent, videoLink: URL?) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let overlayView = OverlayView(
            eventTitle: event.title ?? "Meeting",
            startTime: event.startDate,
            location: event.location,
            videoLink: videoLink,
            onDismiss: { [weak self] in
                self?.close()
            },
            onJoin: { [weak self] url in
                NSWorkspace.shared.open(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.close()
                }
            }
        )

        window.contentView = NSHostingView(rootView: overlayView)
        return window
    }

    func showWindow(_ sender: Any?) {
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Auto-dismiss after 45 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.close()
        }
    }

    func close() {
        // Guard against double-close
        guard !isClosed else { return }
        isClosed = true

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}

// Hand cursor modifier for buttons
struct HandCursorOnHover: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct OverlayView: View {
    let eventTitle: String
    let startTime: Date
    let location: String?
    let videoLink: URL?
    let onDismiss: () -> Void
    let onJoin: (URL) -> Void

    @State private var pulse = false
    @State private var secondsLeft: Int = 60

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                Image(systemName: "bell.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.red)
                    .scaleEffect(pulse ? 1.2 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                        value: pulse
                    )

                Text("MEETING STARTING")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundColor(.red)
                    .tracking(4)

                Text(eventTitle)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Text(timeString)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))

                if let location = location, !location.isEmpty,
                   !location.starts(with: "https://") {
                    Text(location)
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer().frame(height: 20)

                HStack(spacing: 24) {
                    if let videoLink = videoLink {
                        Button(action: { onJoin(videoLink) }) {
                            HStack(spacing: 12) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 22))
                                Text("Join Meeting")
                                    .font(.system(size: 22, weight: .bold))
                            }
                            .padding(.horizontal, 40)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.green)
                                    .shadow(color: .green.opacity(0.5), radius: 20, y: 5)
                            )
                            .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .modifier(HandCursorOnHover())
                    }

                    Button(action: onDismiss) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark")
                                .font(.system(size: 18))
                            Text("Dismiss")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.1))
                                )
                        )
                        .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .modifier(HandCursorOnHover())
                }

                Spacer()
            }
        }
        .onAppear {
            pulse = true
            startCountdown()
        }
    }

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let startStr = formatter.string(from: startTime)

        if secondsLeft > 0 {
            return "Starts at \(startStr) — \(secondsLeft)s away"
        } else {
            return "Started at \(startStr) — NOW"
        }
    }

    func startCountdown() {
        let now = Date()
        secondsLeft = max(0, Int(startTime.timeIntervalSince(now)))

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            let now = Date()
            secondsLeft = max(0, Int(startTime.timeIntervalSince(now)))
            if secondsLeft <= 0 {
                timer.invalidate()
            }
        }
    }
}
