import AppKit
import Carbon.HIToolbox

/// Global hotkey service using CGEvent tap.
///
/// Listens for modifier key press/release to implement hold-to-record.
/// Default: hold Option key.
///
/// This class is intentionally not Sendable — it must be created and used
/// on the main thread. The CGEvent callback dispatches back to main.
final class HotkeyService: @unchecked Sendable {
    var onHotkeyDown: (@Sendable () -> Void)?
    var onHotkeyUp: (@Sendable () -> Void)?

    private var eventTap: CFMachPort?
    private var isHotkeyHeld = false

    /// The modifier key to use for hold-to-record.
    var modifierKey: CGEventFlags = .maskAlternate // Option key

    func register() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Accessibility permission required.")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            let flags = event.flags

            if flags.contains(modifierKey) && !isHotkeyHeld {
                isHotkeyHeld = true
                let callback = onHotkeyDown
                DispatchQueue.main.async { callback?() }
            } else if !flags.contains(modifierKey) && isHotkeyHeld {
                isHotkeyHeld = false
                let callback = onHotkeyUp
                DispatchQueue.main.async { callback?() }
            }
        }

        return Unmanaged.passRetained(event)
    }

    func unregister() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    deinit {
        unregister()
    }
}
