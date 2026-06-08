import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct QuestradeTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let apiServer: URL
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case apiServer = "api_server"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct QuestradeBalancesResponse: Decodable {
    let combinedBalances: [CombinedBalance]

    struct CombinedBalance: Decodable {
        let currency: String
        let totalEquity: Double?
        let marketValue: Double?
        let dailyProfitLoss: Double?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalEquity
            case marketValue
            case dailyProfitLoss
        }
    }
}

struct QuestradePositionsResponse: Decodable {
    let positions: [Position]

    struct Position: Decodable, Equatable {
        let symbol: String
        let openQuantity: Double
        let currentMarketValue: Double
        let currentPrice: Double?

        enum CodingKeys: String, CodingKey {
            case symbol
            case openQuantity
            case currentMarketValue
            case currentPrice
        }
    }
}

struct AccountSnapshot: Equatable {
    let accountValue: Double
    let dailyChange: Double
    let topPositions: [QuestradePositionsResponse.Position]
    let currency: String

    static func build(
        balances: QuestradeBalancesResponse,
        positions: QuestradePositionsResponse,
        topLimit: Int = 5
    ) -> AccountSnapshot? {
        guard let primaryBalance = balances.combinedBalances.first else {
            return nil
        }

        let sortedPositions = positions.positions
            .sorted { abs($0.currentMarketValue) > abs($1.currentMarketValue) }

        return AccountSnapshot(
            accountValue: primaryBalance.totalEquity ?? primaryBalance.marketValue ?? 0,
            dailyChange: primaryBalance.dailyProfitLoss ?? 0,
            topPositions: Array(sortedPositions.prefix(topLimit)),
            currency: primaryBalance.currency
        )
    }
}

enum QuestradeClientError: Error {
    case invalidAuthURL
    case invalidEndpoint
    case invalidResponse
    case missingSnapshotData
}

actor QuestradeClient {
    struct Config: Equatable {
        let refreshToken: String
        let accountID: String
        let authTokenURL: URL
    }

    private struct SessionState {
        let accessToken: String
        let refreshToken: String
        let apiServer: URL
        let expiryDate: Date
    }

    private let config: Config
    private let session: URLSession
    private var state: SessionState?

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetchSnapshot() async throws -> AccountSnapshot {
        let activeState = try await validState(forceRefresh: false)
        let balances: QuestradeBalancesResponse = try await requestJSON(
            path: "/v1/accounts/\(config.accountID)/balances",
            state: activeState
        )
        let positions: QuestradePositionsResponse = try await requestJSON(
            path: "/v1/accounts/\(config.accountID)/positions",
            state: activeState
        )

        guard let snapshot = AccountSnapshot.build(balances: balances, positions: positions) else {
            throw QuestradeClientError.missingSnapshotData
        }

        return snapshot
    }

    private func validState(forceRefresh: Bool) async throws -> SessionState {
        if !forceRefresh,
           let state,
           state.expiryDate.timeIntervalSinceNow > 60 {
            return state
        }

        var components = URLComponents(url: config.authTokenURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: state?.refreshToken ?? config.refreshToken)
        ]

        guard let tokenURL = components?.url else {
            throw QuestradeClientError.invalidAuthURL
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw QuestradeClientError.invalidResponse
        }

        let token = try JSONDecoder().decode(QuestradeTokenResponse.self, from: data)
        let nextState = SessionState(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            apiServer: token.apiServer,
            expiryDate: Date().addingTimeInterval(TimeInterval(max(token.expiresIn - 120, 60)))
        )
        state = nextState
        return nextState
    }

    private func requestJSON<T: Decodable>(path: String, state: SessionState) async throws -> T {
        guard let requestURL = URL(string: path, relativeTo: state.apiServer) else {
            throw QuestradeClientError.invalidEndpoint
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("\(state.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuestradeClientError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            let refreshed = try await validState(forceRefresh: true)
            return try await requestJSON(path: path, state: refreshed)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw QuestradeClientError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

#if canImport(SwiftUI) && os(macOS)
import SwiftUI

@MainActor
final class SnapshotStore: ObservableObject {
    private static let refreshTokenKey = "questrade.refreshToken"
    private static let accountIDKey = "questrade.accountID"

    @Published var refreshToken: String {
        didSet { UserDefaults.standard.set(refreshToken, forKey: Self.refreshTokenKey) }
    }

    @Published var accountID: String {
        didSet { UserDefaults.standard.set(accountID, forKey: Self.accountIDKey) }
    }

    @Published var snapshot: AccountSnapshot?
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var pollTask: Task<Void, Never>?
    private var client: QuestradeClient?
    private var activeConfig: QuestradeClient.Config?

    init() {
        refreshToken = UserDefaults.standard.string(forKey: Self.refreshTokenKey) ?? ""
        accountID = UserDefaults.standard.string(forKey: Self.accountIDKey) ?? ""
    }

    deinit {
        pollTask?.cancel()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func reload() async {
        let trimmedToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedToken.isEmpty, !trimmedAccount.isEmpty else {
            snapshot = nil
            errorMessage = "Add account ID and refresh token below."
            return
        }

        isLoading = true
        defer { isLoading = false }

        let config = QuestradeClient.Config(
            refreshToken: trimmedToken,
            accountID: trimmedAccount,
            authTokenURL: URL(string: "https://login.questrade.com/oauth2/token")!
        )

        if config != activeConfig {
            client = QuestradeClient(config: config)
            activeConfig = config
        }

        do {
            guard let client else { return }
            let latest = try await client.fetchSnapshot()
            snapshot = latest
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to fetch account data: \(error.localizedDescription)"
        }
    }

    var menuBarTitle: String {
        guard let snapshot else {
            return "Questrade"
        }

        return "\(formatCurrency(snapshot.accountValue, currency: snapshot.currency))"
    }

    func formatCurrency(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

@main
struct questrade_mac_menu: App {
    @StateObject private var store = SnapshotStore()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                Text("Questrade")
                    .font(.headline)

                if let snapshot = store.snapshot {
                    Text("Account Value: \(store.formatCurrency(snapshot.accountValue, currency: snapshot.currency))")
                    Text("Daily Change: \(store.formatCurrency(snapshot.dailyChange, currency: snapshot.currency))")

                    Divider()
                    Text("Top Positions")
                        .font(.subheadline)

                    ForEach(Array(snapshot.topPositions.enumerated()), id: \.offset) { _, position in
                        HStack {
                            Text(position.symbol)
                            Spacer()
                            Text(store.formatCurrency(position.currentMarketValue, currency: snapshot.currency))
                        }
                    }

                    if let lastUpdated = store.lastUpdated {
                        Text("Updated: \(lastUpdated.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Divider()

                TextField("Account ID", text: $store.accountID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Refresh Token", text: $store.refreshToken)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Reload Now") {
                        Task { await store.reload() }
                    }
                    .disabled(store.isLoading)

                    Button("Start Polling") {
                        store.startPolling()
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 320)
            .task {
                store.startPolling()
            }
        } label: {
            Text(store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
#else
@main
struct questrade_mac_menu {
    static func main() {
        print("This package contains a macOS menu bar app and must run on macOS.")
    }
}
#endif
