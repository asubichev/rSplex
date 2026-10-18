import CoreMIDI
import rSplexCore

/// Where MIDI goes: a hardware/software destination, or rSplex's own virtual source (which DAWs list as an input).
struct MIDITarget: Equatable {
    var name: String
    /// nil means the virtual source.
    var destination: MIDIEndpointRef?
}

/// CoreMIDI plumbing: the client, an output port, the "rSplex" virtual source, and the list of destinations,
/// kept current as devices come and go.
final class MIDIOutput {
    static let virtualName = "rSplex (virtual)"
    private var client = MIDIClientRef()
    private(set) var port = MIDIPortRef()
    private(set) var virtualSource = MIDIEndpointRef()
    private(set) var targets: [MIDITarget] = []
    /// Called on the main thread when the destination list changes.
    var onChange: (() -> Void)?

    init() {
        MIDIClientCreateWithBlock("rSplex" as CFString, &client) { [weak self] n in
            guard n.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.refresh() }
        }
        MIDIOutputPortCreate(client, "rSplex out" as CFString, &port)
        MIDISourceCreateWithProtocol(client, "rSplex" as CFString, ._1_0, &virtualSource)
        refresh()
    }

    func refresh() {
        let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter { $0 != 0 }
        targets = [MIDITarget(name: Self.virtualName, destination: nil)]
            + destinations.map { MIDITarget(name: Self.displayName($0), destination: $0) }
        onChange?()
    }

    private static func displayName(_ e: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name)
        return name?.takeRetainedValue() as String? ?? "MIDI \(e)"
    }

    /// Sends `list` to a target. Safe from the audio thread.
    func send(_ list: UnsafePointer<MIDIEventList>, to t: MIDITarget) {
        if let d = t.destination { MIDISendEventList(port, d, list) } else { MIDIReceivedEventList(virtualSource, list) }
    }

    /// Note-off for every pitch plus All Notes Off, right now. For quitting or switching targets, so nothing hangs.
    func panic(_ t: MIDITarget) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        buffer.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            var packet = MIDIEventListInit(list, ._1_0)
            for m in (0..<128).map({ MIDIMessage.noteOff(UInt8($0)) }) + [.allNotesOff] {
                var w = m.umpWord(channel: 0)
                packet = MIDIEventListAdd(list, raw.count, packet, 0, 1, &w)
            }
            send(list, to: t)
        }
    }
}
