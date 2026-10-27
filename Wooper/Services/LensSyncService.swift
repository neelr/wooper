import CoreBluetooth
import Foundation

/// print() block-buffers on a pipe, which eats console output when launched
/// via devicectl — log lines must flush immediately to be seen live.
@inline(__always) func lensLog(_ message: String) {
    fputs(message + "\n", stdout)
    fflush(stdout)
}

/// Pushes the Papery reading list to the e-reader over BLE and relays its
/// offline read-toggles back to the server. The reader advertises a GATT
/// service whenever its list screen is awake; this central spots it (including
/// from the background, via the bluetooth-central mode), connects, and drives
/// the whole sync — the device never initiates anything.
///
/// Protocol (device notifies a Control response for every command):
///   MAN?          -> manifest lines "M:<id>:<cachedAt>:<read>:<pending>" on
///                    the Manifest characteristic, then Control "MAN_END:<n>"
///   RACK:<id>     -> "RACK_OK:<id>" once the device clears that pending flag
///   IDX:<bytes>   -> "IDX_GO", stream NDJSON on Data, then "IDX_OK:<n>"
///   BND:<bytes>   -> "BND_GO", stream bundle frames on Data, then "BND_OK:.."
///   DONE          -> "BYE"
///   flow control  -> device notifies "ACK:<total>" every 4KB it consumes;
///                    keep at most 8KB unacknowledged in flight.
///
/// Stateful singleton in the AudioRecorderService mold: `@Observable` so the
/// Papery tab can show live status.
@Observable
final class LensSyncService: NSObject {
    static let shared = LensSyncService()

    // MARK: observable status

    enum Status: Equatable {
        case bluetoothOff
        case scanning
        case connecting
        case syncing(String)
        case idle(lastSync: Date?)
        case error(String)
    }

    private(set) var status: Status = .scanning
    private(set) var lastSyncDate: Date? = UserDefaults.standard.object(forKey: "lensLastSync") as? Date

    var statusText: String {
        switch status {
        case .bluetoothOff: return "bluetooth off"
        case .scanning: return "looking for lens…"
        case .connecting: return "connecting…"
        case .syncing(let step): return step
        case .idle(let date):
            guard let date else { return "not synced yet" }
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .abbreviated
            return "synced \(fmt.localizedString(for: date, relativeTo: Date()))"
        case .error(let message): return message
        }
    }

    // MARK: BLE plumbing

    private static let serviceUUID = CBUUID(string: "7AB21E10-5C92-4F60-8AAB-CF1E69E00001")
    private static let controlUUID = CBUUID(string: "7AB21E10-5C92-4F60-8AAB-CF1E69E00002")
    private static let dataUUID = CBUUID(string: "7AB21E10-5C92-4F60-8AAB-CF1E69E00003")
    private static let manifestUUID = CBUUID(string: "7AB21E10-5C92-4F60-8AAB-CF1E69E00004")
    // Bytes in flight before we wait for ACK. The device ACKs bytes it has
    // *drained to SD*, so ring occupancy is bounded by this window — 6KB
    // against the 8KB ring keeps 2KB of headroom while leaving fewer stalls
    // waiting on the ACK round-trip during bulk streams.
    private static let ackWindow = 6144
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var manifestChar: CBCharacteristic?
    private var lastAttempt = Date.distantPast
    /// We changed server state from this phone (toggled/saved in the app), so
    /// the reader is stale even if it isn't asking for a visit.
    private var serverDirty = UserDefaults.standard.bool(forKey: "lensServerDirty")
    private var manualRequested = false

    /// Call after any papery mutation made on the phone; the next sighting of
    /// the reader syncs immediately instead of waiting for its 5-min window.
    func markServerDirty() {
        serverDirty = true
        UserDefaults.standard.set(true, forKey: "lensServerDirty")
    }

    // MARK: sync state machine

    private enum Step {
        case idle
        case awaitingManifest
        case pushingReads
        case awaitingIdxGo
        case streamingIndex
        case awaitingIdxOk
        case awaitingBndGo
        case streamingBundle
        case awaitingBndOk
        case awaitingBye
    }

    private struct ManifestEntry {
        let id: Int
        let cachedAt: UInt32
        let read: Bool
        let pending: Bool
    }

    private var step: Step = .idle
    private var manifest: [ManifestEntry] = []
    private var pendingReads: [ManifestEntry] = []
    private var indexData = Data()
    private var wantedIDs: [(id: Int, textAt: UInt32)] = []
    private var bundleQueue: [Data] = []
    private var outgoing = Data()
    private var outgoingSent = 0
    private var deviceAcked: UInt32 = 0
    private var offline = false
    private var totalWritten = 0

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "lens-sync"]
        )
    }

    /// Manual kick from the UI: forget the cooldown and rescan immediately.
    func syncNow() {
        manualRequested = true
        lastAttempt = .distantPast
        if let peripheral, peripheral.state == .connected {
            startSync()
        } else {
            restartScan()
        }
    }

    // MARK: - internals

    private func restartScan() {
        guard central.state == .poweredOn else {
            lensLog("[lens] restartScan skipped, central state=\(central.state.rawValue)")
            return
        }
        central.stopScan()
        // Filtered on the service UUID: this is also what lets iOS deliver
        // discoveries while the app is backgrounded, so the reader gets topped
        // up from a pocketed phone.
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        lensLog("[lens] scanning")
        // Scanning is the resting state between visits — don't let it stomp the
        // "synced Xm ago" message; only show "looking" when we've never synced.
        if case .syncing = status {
        } else if lastSyncDate == nil {
            status = .scanning
        } else {
            status = .idle(lastSync: lastSyncDate)
        }
    }

    private func startSync() {
        guard let controlChar, let peripheral else { return }
        manifest = []
        pendingReads = []
        indexData = Data()
        wantedIDs = []
        bundleQueue = []
        outgoing = Data()
        outgoingSent = 0
        deviceAcked = 0
        totalWritten = 0
        step = .awaitingManifest
        status = .syncing("reading device state…")
        // The reader has no other wall-clock source (no WiFi/NTP, no RTC on
        // X4): stamp it on every visit. Fire-and-forget; no reply expected.
        let epoch = UInt32(Date().timeIntervalSince1970)
        peripheral.writeValue(Data("TIME:\(epoch)".utf8), for: controlChar, type: .withResponse)
        peripheral.writeValue(Data("MAN?".utf8), for: controlChar, type: .withResponse)
    }

    private func finish(_ result: Status) {
        step = .idle
        status = result
        if case .idle(let date) = result, let date {
            lastSyncDate = date
            UserDefaults.standard.set(date, forKey: "lensLastSync")
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: control-notification state machine

    private func handleControl(_ text: String) {
        if text.hasPrefix("ACK:") {
            deviceAcked = UInt32(text.dropFirst(4)) ?? deviceAcked
            pumpOutgoing()
            return
        }
        if text.hasPrefix("ERR:") {
            finish(.error("device: \(text)"))
            return
        }

        switch step {
        case .awaitingManifest where text.hasPrefix("MAN_END:"):
            pendingReads = manifest.filter { $0.pending }
            step = .pushingReads
            pushNextRead()
        case .pushingReads where text.hasPrefix("RACK_OK:"):
            pushNextRead()
        case .awaitingIdxGo where text == "IDX_GO":
            step = .streamingIndex
            outgoing = indexData
            outgoingSent = 0
            pumpOutgoing()
        case .awaitingIdxOk where text.hasPrefix("IDX_OK:"):
            startNextBundle()
        case .awaitingBndGo where text == "BND_GO":
            step = .streamingBundle
            pumpOutgoing()
        case .awaitingBndOk where text.hasPrefix("BND_OK:"):
            startNextBundle()
        case .awaitingBye where text == "BYE":
            serverDirty = false
            UserDefaults.standard.set(false, forKey: "lensServerDirty")
            finish(.idle(lastSync: Date()))
        default:
            break
        }
    }

    private func pushNextRead() {
        guard let peripheral, let controlChar else { return }
        guard let next = pendingReads.first else {
            fetchAndPushIndex()
            return
        }
        pendingReads.removeFirst()
        status = .syncing("sending read states…")
        Task { @MainActor in
            // Relay to papery, or queue durably when offline — either way the
            // phone now owns delivery, so the device may clear its flag.
            do {
                try await PaperyService.setRead(id: next.id, read: next.read)
            } catch {
                PaperyCache.queuePendingRead(id: next.id, read: next.read)
            }
            peripheral.writeValue(Data("RACK:\(next.id)".utf8), for: controlChar, type: .withResponse)
        }
    }

    private func fetchAndPushIndex() {
        guard let peripheral, let controlChar else { return }
        status = .syncing("fetching index…")
        Task { @MainActor in
            do {
                self.indexData = try await PaperyService.deviceIndexNDJSON()
                PaperyCache.saveIndex(self.indexData)
                self.offline = false
            } catch {
                // No internet: serve the reader from the last-known-good cache.
                guard let cached = PaperyCache.loadIndex() else {
                    self.finish(.error("papery: \(error.localizedDescription)"))
                    return
                }
                lensLog("[lens] offline — using cached index")
                self.indexData = cached
                self.offline = true
            }
            self.computeWanted()
            self.step = .awaitingIdxGo
            peripheral.writeValue(Data("IDX:\(self.indexData.count)".utf8), for: controlChar, type: .withResponse)
        }
    }

    /// An article needs pushing when the server's text version differs from
    /// what the device holds (its manifest cachedAt).
    private func computeWanted() {
        var cachedByID: [Int: UInt32] = [:]
        for entry in manifest { cachedByID[entry.id] = entry.cachedAt }

        wantedIDs = []
        guard let text = String(data: indexData, encoding: .utf8) else { return }
        for line in text.split(separator: "\n").dropFirst() {  // first line is the header
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            let textAt = UInt32(obj["text_at"] as? Int ?? 0)
            guard textAt != 0 else { continue }
            if cachedByID[id] != textAt { wantedIDs.append((id, textAt)) }
        }
        lensLog("[lens] manifest=\(manifest.count) wanted=\(wantedIDs.count) \(wantedIDs.prefix(6).map { "\($0.id)@\($0.textAt)" }.joined(separator: " "))")
    }

    private func startNextBundle() {
        guard let peripheral, let controlChar else { return }
        if let ready = bundleQueue.first {
            bundleQueue.removeFirst()
            outgoing = ready
            outgoingSent = 0
            step = .awaitingBndGo
            peripheral.writeValue(Data("BND:\(ready.count)".utf8), for: controlChar, type: .withResponse)
            return
        }
        if wantedIDs.isEmpty {
            step = .awaitingBye
            status = .syncing("finishing…")
            peripheral.writeValue(Data("DONE".utf8), for: controlChar, type: .withResponse)
            return
        }
        let batch = Array(wantedIDs.prefix(25))
        wantedIDs.removeFirst(batch.count)
        status = .syncing("fetching \(batch.count) articles…")
        Task { @MainActor in
            // Cache first: anything already held locally costs no network at all.
            let (frames, missing) = PaperyCache.buildFrames(batch)
            if missing.isEmpty {
                self.bundleQueue.append(frames)
                self.startNextBundle()
                return
            }
            do {
                let data = try await PaperyService.bundleData(ids: missing)
                let versions = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.textAt) })
                PaperyCache.ingestBundle(data, versions: versions)
                var combined = frames
                combined.append(data)
                self.bundleQueue.append(combined)
                self.startNextBundle()
            } catch {
                // Offline: ship what the cache had; the rest lands next time.
                lensLog("[lens] offline — \(missing.count) articles skipped")
                if !frames.isEmpty { self.bundleQueue.append(frames) }
                self.startNextBundle()
            }
        }
    }

    // MARK: data streaming with flow control

    private func pumpOutgoing() {
        guard let peripheral, let dataChar else { return }
        guard step == .streamingIndex || step == .streamingBundle else { return }

        let chunk = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        while outgoingSent < outgoing.count {
            // App-level credit window on top of CB's own buffer readiness, so
            // the reader's 16KB ring can never overflow.
            let unacked = totalWritten - Int(deviceAcked)
            if unacked >= Self.ackWindow { return }
            if !peripheral.canSendWriteWithoutResponse { return }
            let end = min(outgoingSent + chunk, outgoing.count)
            peripheral.writeValue(outgoing[outgoingSent..<end], for: dataChar, type: .withoutResponse)
            totalWritten += end - outgoingSent
            outgoingSent = end
        }

        if outgoingSent >= outgoing.count {
            if step == .streamingIndex {
                step = .awaitingIdxOk
                status = .syncing("device applying index…")
            } else {
                step = .awaitingBndOk
                status = .syncing("device saving articles…")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LensSyncService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        lensLog("[lens] central state -> \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            restartScan()
        case .poweredOff, .unauthorized, .unsupported:
            status = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us for a BLE event. Re-adopt any restored peripheral;
        // the connect/discover callbacks take it from there.
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = restored.first {
            peripheral = first
            first.delegate = self
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        // The DEVICE owns sync policy. Its advertisement carries two bits:
        // bit0 = interactive changes pending (visit right now), bit1 = routine
        // consistency window open (5 min since its last sync). Neither set
        // means "leave me alone" — unless we ourselves changed server state
        // (serverDirty) or the user pressed sync. The only phone-side rule is
        // a 5s storm-guard floor.
        var devicePending = false
        var deviceDue = false
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.count >= 3, mfg[0] == 0xff, mfg[1] == 0xff {
            devicePending = mfg[2] & 1 == 1
            deviceDue = mfg[2] & 2 == 2
        }
        guard devicePending || deviceDue || serverDirty || manualRequested else { return }
        guard Date().timeIntervalSince(lastAttempt) > 5 else { return }
        lensLog("[lens] found \(peripheral.name ?? "lens") rssi=\(RSSI) pending=\(devicePending) due=\(deviceDue) dirty=\(serverDirty)")
        manualRequested = false
        lastAttempt = Date()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        status = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        restartScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        controlChar = nil
        dataChar = nil
        manifestChar = nil
        if step != .idle {
            step = .idle
            status = .error("disconnected mid-sync")
        }
        restartScan()
    }
}

// MARK: - CBPeripheralDelegate

extension LensSyncService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.controlUUID, Self.dataUUID, Self.manifestUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case Self.controlUUID:
                controlChar = char
                peripheral.setNotifyValue(true, for: char)
            case Self.dataUUID:
                dataChar = char
            case Self.manifestUUID:
                manifestChar = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }
        if controlChar != nil, dataChar != nil, manifestChar != nil {
            startSync()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let text = String(data: data, encoding: .utf8) else { return }

        if characteristic.uuid == Self.manifestUUID {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":")
                guard parts.count == 5, parts[0] == "M",
                      let id = Int(parts[1]), let cachedAt = UInt32(parts[2])
                else { continue }
                manifest.append(ManifestEntry(id: id, cachedAt: cachedAt, read: parts[3] == "1", pending: parts[4] == "1"))
            }
            return
        }
        if characteristic.uuid == Self.controlUUID {
            lensLog("[lens] control <- \(text)")
            handleControl(text)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpOutgoing()
    }
}
