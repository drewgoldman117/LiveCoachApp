// BuzzerLink.swift
//
// CoreBluetooth link to the Shelly BLU Button Tough 1 - the alert output.
// Swift port of the Python prototype's `src/buzzer.py`; the BEHAVIOR is what
// carries over, and every rule here was paid for on real hardware (see that
// repo's CLAUDE.md, "The buzzer"):
//
//   - Open the link ONCE and HOLD it. Connect costs ~16s (mostly waiting for
//     the device to advertise), a write ~35ms. A connect-per-alert is impossible.
//     Verified: 6/6 beeps landed over 90s on a held link, untouched.
//   - Beacon mode (0x01 to CHAR_BEACON) must be enabled or the device is
//     unreachable when asleep.
//   - A SLEEPING button is invisible to a scan, and beacon mode does not fix
//     that. The user must press it to make it connectable, so the UI has to ASK
//     rather than spin forever.
//   - PAIRING A NEW DEVICE NEEDS A 10-SECOND HOLD, not a press. Shelly's BLE
//     docs: "Connection is only possible from a paired devices, or if pairing
//     mode is active." A short press only wakes the BTHome beacon - the device
//     advertises, shows up in a scan, reports itself CONNECTABLE, and still
//     refuses the connection. That dead end (visible, connectable, never
//     connects, and no error anywhere) is unfixable in code and cost hours
//     here; the pairing screen leads with the hold for that reason. An
//     already-paired central connects on a mere press forever after, which is
//     why the Mac prototype never appeared to need it.
//   - buzz() must never block the capture loop, must coalesce (several requests
//     during one beep = one beep) and must rate-limit.
//
// iOS makes one part much easier than macOS did: `connect(peripheral)` has no
// timeout and stays PENDING until the peripheral becomes connectable. So there
// is no scan loop and no retry timer here - we issue one standing connect and it
// completes whenever the user presses the button, however much later that is.
//
// Note the peripheral identifier is per-app/per-device: the UUID this app stores
// is NOT the one the Mac prototype uses for the same button, so it can only be
// discovered by pairing, never hardcoded.

import CoreBluetooth
import Foundation

enum BuzzerState: Equatable {
    case unpaired               // no device remembered yet
    case waitingForDevice       // standing connect issued; press the button
    case connected
    case unauthorized           // Bluetooth permission denied / off
}

final class BuzzerLink: NSObject, ObservableObject {

    // Shelly BLU GATT. Bonded writes: iOS raises the pairing prompt on first access.
    static let service = CBUUID(string: "de8a5aac-a99b-c315-0c80-60d4cbb51225")
    static let charBuzzer = CBUUID(string: "5b026510-4088-c297-46d8-be6c736a087b")   // 0x01 on / 0x00 off
    static let charVolume = CBUUID(string: "dd78bf35-7680-484e-ad86-1bc1e7738e14")   // 0...3
    static let charBeacon = CBUUID(string: "cb9e957e-952d-4761-a7e1-4416494a5bfa")   // 0x01 = required
    /// BTHome. A Shelly BLU has no useful advertised name on some stacks, so this
    /// is how it's picked out of a scan.
    static let bthome = CBUUID(string: "FCD2")

    @Published private(set) var state: BuzzerState = .unpaired
    @Published private(set) var beeps = 0
    /// Devices seen during pairing, best signal first.
    @Published private(set) var discovered: [DiscoveredBuzzer] = []
    @Published private(set) var isScanning = false
    /// Progress goes to the CONSOLE, not the screen. The pairing UI says one
    /// thing - press the button - and the buzzer itself confirms success by
    /// beeping; a running commentary of BLE stages is for debugging this class,
    /// not for someone standing on a court.
    private func note(_ s: String) {
        print("Buzzer: \(s)")
    }

    struct DiscoveredBuzzer: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    var volume: UInt8 = 3               // 0 off ... 3 high; a court is loud
    /// Short blip, not an alarm - mid-point you want a cue you can ignore.
    /// Longer than the prototype's 90ms: hardware volume is already at its
    /// max (3), so duration is the only loudness lever left, and a 90ms blip
    /// disappears outdoors under play noise.
    var beepDuration: TimeInterval = 0.4
    var minGap: TimeInterval = 2.0      // never beep more often than this

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Peripherals from the current scan, held STRONGLY and keyed by id.
    ///
    /// Two CoreBluetooth rules make this mandatory, and missing them is exactly
    /// why tapping a scanned device used to do nothing at all:
    ///   1. `retrievePeripherals(withIdentifiers:)` only returns peripherals the
    ///      system ALREADY knows (previously connected or bonded). One just
    ///      discovered by a scan is not among them, so that lookup returned an
    ///      empty array and `pair()` fell straight out of its `guard` in
    ///      silence - the device listed, the tap did nothing.
    ///   2. A CBPeripheral you do not retain is deallocated, and a connect to a
    ///      deallocated peripheral never completes.
    private var seen: [UUID: CBPeripheral] = [:]
    private var buzzChar: CBCharacteristic?
    private var beaconChar: CBCharacteristic?
    private var volumeChar: CBCharacteristic?
    private var lastBuzz = Date.distantPast
    private var setupRetried = false
    private var connectStarted = Date()
    private var connectTimer: Timer?
    /// When the target last advertised - i.e. when it was last awake.
    private var lastAdvert: Date?
    /// Whether that last advertisement said it would accept a connection.
    private var lastAdvertConnectable = false
    /// True while re-scanning specifically to catch the device advertising.
    private var rescanning = false
    /// The ready-chime fires once per link, on the first bonded write that
    /// actually succeeds - see `didWriteValueFor`.
    private var chimed = false
    private let queue = DispatchQueue(label: "buzzer.ble")

    private static let savedIdentifierKey = "buzzer.peripheral.identifier"
    private var savedIdentifier: UUID? {
        get { (UserDefaults.standard.string(forKey: Self.savedIdentifierKey)).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.savedIdentifierKey) }
    }

    var isPaired: Bool { savedIdentifier != nil }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - Session use

    /// Re-attach to the remembered button. Returns immediately; the connect sits
    /// pending until the user presses it, so the UI just watches `state`.
    func connectSaved() {
        guard let id = savedIdentifier else { return }
        guard central.state == .poweredOn else { return }     // retried in didUpdateState
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        attach(p)
    }

    /// Ask for one beep. Non-blocking, coalescing, rate-limited. Safe to call
    /// from the capture loop; returns false if it was dropped.
    @discardableResult
    func buzz() -> Bool {
        guard Date().timeIntervalSince(lastBuzz) >= minGap else { return false }
        guard state == .connected, let p = peripheral, let c = buzzChar else { return false }
        lastBuzz = Date()
        queue.async { [weak self] in
            guard let self else { return }
            p.writeValue(Data([0x01]), for: c, type: .withResponse)
            self.queue.asyncAfter(deadline: .now() + self.beepDuration) {
                p.writeValue(Data([0x00]), for: c, type: .withResponse)
                DispatchQueue.main.async { self.beeps += 1 }
            }
        }
        return true
    }

    /// Beep `times` in quick succession - the audible "I'm paired and ready"
    /// signal, so you know the link is live without looking at the phone (which
    /// is the point: it's zip-tied to a fence).
    ///
    /// Deliberately bypasses `minGap`: that limit exists to stop tactical alerts
    /// running together during a rally, and this is a single deliberate
    /// confirmation, not an alert.
    func chime(times: Int = 3, on: TimeInterval = 0.07, off: TimeInterval = 0.11) {
        guard let p = peripheral, let c = buzzChar else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for i in 0..<times {
                let start = Double(i) * (on + off)
                self.queue.asyncAfter(deadline: .now() + start) {
                    p.writeValue(Data([0x01]), for: c, type: .withResponse)
                }
                self.queue.asyncAfter(deadline: .now() + start + on) {
                    p.writeValue(Data([0x00]), for: c, type: .withResponse)
                }
            }
        }
    }

    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        buzzChar = nil
        savedIdentifier = nil
        publish(.unpaired)
    }

    // MARK: - Pairing

    /// Scan for candidates. `nil` services because a sleeping/awake Shelly does
    /// not reliably advertise its GATT service UUID - it's identified by name or
    /// by its BTHome service data instead. Foreground-only, which is fine: this
    /// runs from a pairing sheet the user is looking at.
    func startScan() {
        guard central.state == .poweredOn else { return publish(.unauthorized) }
        DispatchQueue.main.async { self.discovered = []; self.isScanning = true }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        central.stopScan()
        DispatchQueue.main.async { self.isScanning = false }
    }

    /// Pair with a scanned device: remember it and connect.
    ///
    /// Connects to the RETAINED peripheral from the scan. Looking it up with
    /// `retrievePeripherals(withIdentifiers:)` instead does not work for a
    /// device that has never been connected - see `seen`.
    func pair(_ found: DiscoveredBuzzer) {
        stopScan()
        guard let p = seen[found.id] ?? central.retrievePeripherals(withIdentifiers: [found.id]).first
        else {
            print("Buzzer: no peripheral object for \(found.id) - cannot connect.")
            return
        }
        savedIdentifier = found.id
        note("pairing with \(found.name)…")
        attach(p)
    }

    // MARK: - Internals

    /// Seconds of a pending connect before the whole scan->connect cycle is
    /// retried, mirroring buzzer.py's RETRY_DELAY_S loop.
    private let retryEverySeconds: TimeInterval = 10

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        publish(.waitingForDevice)
        connectStarted = Date()
        central.stopScan()               // never scan while a connect is in flight
        central.connect(p, options: nil)
        startConnectWatchdog(p)
    }

    /// Scan until the target is seen, then connect immediately - the Shelly is
    /// connectable only for a moment after a press, and connecting AT that
    /// moment is what the Python does and what this was missing.
    private func rescanThenConnect() {
        rescanning = true
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    /// Report how long the connect has been pending, and re-issue it
    /// periodically.
    ///
    /// A Shelly sleeps within seconds of being pressed, and a pending iOS
    /// connect only completes while the device is connectable - so in practice
    /// this needs the button pressed AGAIN, possibly several times. Saying so
    /// with a running clock is the difference between waiting usefully and
    /// concluding the app is broken. Re-issuing also clears the occasional
    /// wedged connect.
    private func startConnectWatchdog(_ p: CBPeripheral) {
        connectTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                guard self.state != .connected else {
                    t.invalidate(); self.connectTimer = nil; return
                }
                let secs = Int(Date().timeIntervalSince(self.connectStarted))
                let seenRecently = self.lastAdvert.map { Date().timeIntervalSince($0) < 4 } ?? false
                if seenRecently && !self.lastAdvertConnectable {
                    // The decisive case: visible, but beaconing only. No amount
                    // of waiting fixes this - it needs pairing mode.
                    self.note("beaconing but NOT connectable (\(secs)s) — HOLD the button ~10s for pairing mode")
                } else if seenRecently {
                    self.note("connectable, connecting… \(secs)s")
                } else {
                    self.note("PRESS THE BUTTON AGAIN — waiting \(secs)s")
                }
                // Retry the way the WORKING Python does it: cancel, re-SCAN to
                // rediscover the device, and connect the moment it is seen -
                // never scanning while a connect is in flight. Reading
                // buzzer.py's _connect back: it completes a scan, closes it,
                // issues one long connect, and on failure disconnects and
                // repeats the whole cycle. That ordering is the part this class
                // had wrong; a connect issued against a peripheral discovered
                // minutes ago is not the same as one issued the instant it
                // advertises, which is the only window a Shelly gives you.
                if secs > 0, secs % Int(self.retryEverySeconds) == 0 {
                    self.note("retrying: rescanning for the button…")
                    self.central.cancelPeripheralConnection(p)
                    self.rescanThenConnect()
                }
            }
        }
    }

    private func publish(_ s: BuzzerState) {
        DispatchQueue.main.async { self.state = s }
    }

    private func looksLikeBuzzer(_ name: String?, _ advertisement: [String: Any]) -> Bool {
        if let name, name.lowercased().contains("shelly") || name.hasPrefix("SBBT") { return true }
        let uuids = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if uuids.contains(Self.bthome) || uuids.contains(Self.service) { return true }
        let data = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return data.keys.contains(Self.bthome)
    }
}

// MARK: - CBCentralManagerDelegate

extension BuzzerLink: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectSaved()                       // resume a remembered button on launch
        case .unauthorized, .poweredOff, .unsupported:
            publish(.unauthorized)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard looksLikeBuzzer(peripheral.name, advertisementData) else { return }
        seen[peripheral.identifier] = peripheral      // retain it, or it deallocates
        if peripheral.identifier == self.peripheral?.identifier {
            lastAdvert = Date()
            // Seen it again mid-retry: stop scanning and connect NOW, while it
            // is still advertising. This is the window the Python catches.
            if rescanning {
                rescanning = false
                central.stopScan()
                note("seen advertising - connecting now")
                central.connect(peripheral, options: nil)
            }
        }

        // Just pair with it. There is only ever one buzzer, and making someone
        // pick it out of a list they didn't want to read - while holding a
        // button that sleeps in seconds - is a step with no decision in it.
        if self.peripheral == nil, savedIdentifier == nil {
            let found = DiscoveredBuzzer(id: peripheral.identifier,
                                         name: peripheral.name ?? "Shelly BLU Button",
                                         rssi: RSSI.intValue)
            pair(found)
            return
            // ADVERTISING IS NOT THE SAME AS CONNECTABLE. A Shelly beacons its
            // BTHome data non-connectably most of the time; only in pairing mode
            // does it accept a connection. Without this flag the two look
            // identical from here - the device is visible either way - and a
            // connect against a non-connectable advertiser pends forever, which
            // is exactly the "awake, still connecting" state that never ends.
            lastAdvertConnectable =
                (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        }
        let found = DiscoveredBuzzer(id: peripheral.identifier,
                                     name: peripheral.name ?? "Shelly BLU Button",
                                     rssi: RSSI.intValue)
        DispatchQueue.main.async {
            var list = self.discovered.filter { $0.id != found.id }
            list.append(found)
            self.discovered = list.sorted { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { self.connectTimer?.invalidate(); self.connectTimer = nil }
        central.stopScan()
        note("connected, discovering services…")
        // Discover ALL services, not just the one we want. Filtering by UUID
        // means a firmware that exposes it under any other UUID produces an
        // empty result and a silent dead end; unfiltered, we can at least SAY
        // what the device offers.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        buzzChar = nil
        chimed = false            // the next successful link should announce itself too
        publish(.waitingForDevice)
        // Straight back to a standing connect: it costs nothing while pending
        // and completes the moment the button is next awake.
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        note("connect failed: \(error?.localizedDescription ?? "unknown") - retrying")
        publish(.waitingForDevice)
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BuzzerLink: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            note("service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        note("services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        guard let service = services.first(where: { $0.uuid == Self.service }) else {
            note("Shelly service NOT present (\(services.count) others). Hold the button ~10s for pairing mode.")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            note("characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        note("characteristics: \(chars.count) found")
        beaconChar = chars.first(where: { $0.uuid == Self.charBeacon })
        volumeChar = chars.first(where: { $0.uuid == Self.charVolume })
        buzzChar = chars.first(where: { $0.uuid == Self.charBuzzer })
        setupRetried = false
        if buzzChar == nil {
            note("buzzer characteristic missing - cannot beep")
        }
        writeSetup(peripheral)
        if buzzChar != nil { publish(.connected) }
    }

    /// Beacon FIRST: it's the documented prerequisite for the remote buzzer, and
    /// it makes the device advertise periodically so a later reconnect finds it.
    private func writeSetup(_ peripheral: CBPeripheral) {
        guard beaconChar != nil || volumeChar != nil else {
            note("no bonded characteristic to write - iOS will never show a pairing prompt")
            return
        }
        note("writing setup (this is what raises the iOS pairing prompt)…")
        if let beacon = beaconChar {
            peripheral.writeValue(Data([0x01]), for: beacon, type: .withResponse)
        }
        if let vol = volumeChar {
            peripheral.writeValue(Data([volume]), for: vol, type: .withResponse)
        }
    }

    /// These are BONDED characteristics, so the very first write is also what
    /// raises iOS's pairing prompt - and that write fails while the user is
    /// still looking at the dialog (insufficient authentication/encryption).
    /// Without a retry the device would sit "connected" with beacon mode never
    /// actually set, which is the state where the buzzer silently does nothing.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let error else {
            // A bonded write that SUCCEEDED is the real "ready" signal: it means
            // the pairing prompt was accepted and beacon mode actually took.
            // Chiming on didConnect instead would fire while that dialog is
            // still up, when every write is failing and no beep can sound.
            if characteristic.uuid != Self.charBuzzer, !chimed {
                chimed = true
                note("paired and ready - beeping 3x")
                chime()
            }
            return
        }
        guard characteristic.uuid != Self.charBuzzer else { return }   // a lost beep is not worth retrying
        guard !setupRetried else { return }
        setupRetried = true
        note("setup write failed (\(error.localizedDescription)); retrying after pairing")
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.writeSetup(peripheral)
        }
    }
}
