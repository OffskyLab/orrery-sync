#if canImport(Network)
import Foundation
import Network
import Logging

/// Advertises and discovers orrery-sync peers on the local network via Bonjour/mDNS.
actor BonjourDiscovery {
    static let serviceType = "_orrery-sync._tcp"
    static let domain = "local."

    let peerID: String
    let peerName: String
    let port: Int
    let teamID: String?
    let logger = Logger(label: "orrery-sync.discovery")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discoveredPeers: [String: DiscoveredPeer] = [:]

    let onPeerFound: @Sendable (DiscoveredPeer) async -> Void

    init(peerID: String, peerName: String, port: Int, teamID: String?,
         onPeerFound: @escaping @Sendable (DiscoveredPeer) async -> Void) {
        self.peerID = peerID
        self.peerName = peerName
        self.port = port
        self.teamID = teamID
        self.onPeerFound = onPeerFound
    }

    // MARK: - Advertise

    func startAdvertising() throws {
        let txtRecord = NWTXTRecord([
            "peerID": peerID,
            "peerName": peerName,
            "teamID": teamID ?? "",
            "nmtPort": String(port),
        ])

        let params = NWParameters.tcp
        // Use port 0 — this listener is only for Bonjour advertisement,
        // not for accepting connections. NMT server runs on the real port.
        let listener = try NWListener(using: params, on: .any)
        listener.service = NWListener.Service(
            name: peerID,
            type: Self.serviceType,
            domain: Self.domain,
            txtRecord: txtRecord
        )

        listener.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                logger.info("Bonjour: advertising as \(self.peerName) on port \(self.port)")
            case .failed(let error):
                logger.error("Bonjour advertise failed: \(error)")
            default:
                break
            }
        }

        // We don't actually accept connections on this listener —
        // it's only used for Bonjour advertisement. Real connections
        // go through the NMT server.
        listener.newConnectionHandler = { connection in
            connection.cancel()
        }

        listener.start(queue: DispatchQueue(label: "orrery-sync.bonjour.advertise"))
        self.listener = listener
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Browse

    func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: Self.domain)
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                logger.info("Bonjour: browsing for peers...")
            case .failed(let error):
                logger.error("Bonjour browse failed: \(error)")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { results, changes in
            Task { await self.handleBrowseResults(results, changes: changes) }
        }

        browser.start(queue: DispatchQueue(label: "orrery-sync.bonjour.browse"))
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Private

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handleServiceFound(result)
            case .removed(let result):
                handleServiceLost(result)
            default:
                break
            }
        }
    }

    private func handleServiceFound(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        // Extract TXT record
        var remotePeerID = ""
        var remotePeerName = ""
        var remoteTeamID = ""
        var remoteNMTPort = 0

        if case .bonjour(let txtRecord) = result.metadata {
            remotePeerID = txtRecord.string(for: "peerID") ?? ""
            remotePeerName = txtRecord.string(for: "peerName") ?? ""
            remoteTeamID = txtRecord.string(for: "teamID") ?? ""
            remoteNMTPort = Int(txtRecord.string(for: "nmtPort") ?? "0") ?? 0
        }

        // Skip self
        guard remotePeerID != peerID else { return }

        // Skip if no NMT port
        guard remoteNMTPort > 0 else { return }

        // Skip peers from different teams
        if let myTeam = teamID, !myTeam.isEmpty, !remoteTeamID.isEmpty, myTeam != remoteTeamID {
            logger.debug("Bonjour: ignoring peer \(remotePeerName) — different team")
            return
        }

        logger.info("Bonjour: found peer \(remotePeerName) (\(remotePeerID)) on port \(remoteNMTPort)")

        let peer = DiscoveredPeer(
            peerID: remotePeerID,
            peerName: remotePeerName,
            teamID: remoteTeamID.isEmpty ? nil : remoteTeamID,
            nmtPort: remoteNMTPort,
            endpoint: result.endpoint,
            serviceName: name,
            serviceType: type,
            serviceDomain: domain
        )
        discoveredPeers[remotePeerID] = peer

        let handler = onPeerFound
        Task { await handler(peer) }
    }

    private func handleServiceLost(_ result: NWBrowser.Result) {
        if case .bonjour(let txtRecord) = result.metadata {
            let remotePeerID = txtRecord.string(for: "peerID") ?? ""
            if !remotePeerID.isEmpty {
                discoveredPeers.removeValue(forKey: remotePeerID)
                logger.info("Bonjour: peer left — \(remotePeerID)")
            }
        }
    }
}

struct DiscoveredPeer: Sendable {
    let peerID: String
    let peerName: String
    let teamID: String?
    let nmtPort: Int
    let endpoint: NWEndpoint
    let serviceName: String
    let serviceType: String
    let serviceDomain: String
}

// MARK: - NWTXTRecord helpers

extension NWTXTRecord {
    func string(for key: String) -> String? {
        guard let entry = self.getEntry(for: key) else { return nil }
        if case .string(let value) = entry {
            return value
        }
        return nil
    }
}
#endif
