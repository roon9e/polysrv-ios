import Foundation

/// One address in a server's optional multi-datacenter table.
public struct PolySrvServerDataCenter: Codable, Equatable {
    public let id: Int
    public let host: String
    public let port: Int

    public init(id: Int, host: String, port: Int) {
        self.id = id
        self.host = host
        self.port = port
    }
}

/// A server the client can sign in to. Mirrors the field set of the Android
/// `PolySrvServer` and the desktop `PolySrv::Server` so one `servers.json`
/// serves every platform.
///
/// `isTelegram` is the official cloud: its datacenters and key are built in and
/// it is never locked or overridden. Every other server maps its address onto
/// the datacenters the client asks for (see `host(forDataCenterId:)`).
public struct PolySrvServer: Codable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let host: String
    public let port: Int
    public let rsaPublicKey: String
    public let isTelegram: Bool
    public let isOfficial: Bool
    public let multiDc: Bool
    public let mainDcId: Int
    public let restrictToTcp: Bool
    public let dataCenters: [PolySrvServerDataCenter]

    public init(
        id: String,
        name: String,
        description: String = "",
        host: String,
        port: Int,
        rsaPublicKey: String = "",
        isTelegram: Bool = false,
        isOfficial: Bool = false,
        multiDc: Bool = false,
        mainDcId: Int = 2,
        restrictToTcp: Bool = false,
        dataCenters: [PolySrvServerDataCenter] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.host = host
        self.port = port
        self.rsaPublicKey = rsaPublicKey
        self.isTelegram = isTelegram
        self.isOfficial = isOfficial
        self.multiDc = multiDc
        self.mainDcId = mainDcId
        self.restrictToTcp = restrictToTcp
        self.dataCenters = dataCenters
    }

    public var endpoint: String {
        return "\(self.host):\(self.port)"
    }

    /// The address for a requested datacenter. A server with a DC table answers
    /// per datacenter; a single-machine server answers its one address for
    /// every datacenter, which is what keeps media and migration working.
    public func host(forDataCenterId id: Int) -> String {
        for dc in self.dataCenters where dc.id == id {
            return dc.host
        }
        return self.host
    }

    public func port(forDataCenterId id: Int) -> Int {
        for dc in self.dataCenters where dc.id == id {
            return dc.port
        }
        return self.port
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case host
        case port
        case rsaPublicKey
        case isTelegram
        case isOfficial
        case multiDc
        case mainDcId
        case restrictToTcp
        case dc
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Server"
        self.description = (try? c.decode(String.self, forKey: .description)) ?? ""
        self.host = (try? c.decode(String.self, forKey: .host)) ?? ""
        self.port = (try? c.decode(Int.self, forKey: .port)) ?? 443
        self.rsaPublicKey = (try? c.decode(String.self, forKey: .rsaPublicKey)) ?? ""
        self.isTelegram = (try? c.decode(Bool.self, forKey: .isTelegram)) ?? false
        self.isOfficial = (try? c.decode(Bool.self, forKey: .isOfficial)) ?? false
        self.mainDcId = (try? c.decode(Int.self, forKey: .mainDcId)) ?? 2
        self.restrictToTcp = (try? c.decode(Bool.self, forKey: .restrictToTcp)) ?? false
        let dataCenters = (try? c.decode([PolySrvServerDataCenter].self, forKey: .dc)) ?? []
        self.dataCenters = dataCenters
        self.multiDc = (try? c.decode(Bool.self, forKey: .multiDc)) ?? !dataCenters.isEmpty
    }
}

/// The envelope `servers.json` uses.
struct PolySrvServersConfig: Decodable {
    let version: Int?
    let servers: [PolySrvServer]
}
