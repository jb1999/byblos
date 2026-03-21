import AVFoundation
import CoreAudio

/// Manages microphone permissions and audio device selection on macOS.
///
/// The actual audio capture happens in the Rust core; this service handles
/// the macOS-specific permission flow and device enumeration.
@MainActor
class AudioService: ObservableObject {
    @Published var hasPermission = false
    @Published var availableDevices: [AudioDevice] = []
    @Published var selectedDeviceID: String?

    struct AudioDevice: Identifiable {
        let id: String
        let name: String
        let isDefault: Bool
    }

    init() {
        checkPermission()
        refreshDevices()
    }

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.hasPermission = granted
                }
            }
        default:
            hasPermission = false
        }
    }

    func refreshDevices() {
        // Use CoreAudio to enumerate input devices (works on macOS 13+).
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        ) == noErr else { return }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return }

        // Get default input device.
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInputID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0, nil,
            &defaultSize,
            &defaultInputID
        )

        var devices: [AudioDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input channels.
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &configSize) == noErr else {
                continue
            }
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &configSize, bufferListPtr) == noErr else {
                continue
            }
            let inputChannels = bufferListPtr.pointee.mBuffers.mNumberChannels
            if inputChannels == 0 { continue }

            // Get device name.
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
                  let name = nameRef?.takeRetainedValue() else {
                continue
            }

            devices.append(AudioDevice(
                id: String(deviceID),
                name: name as String,
                isDefault: deviceID == defaultInputID
            ))
        }

        availableDevices = devices
    }
}
