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
        let cash: Double?
        let totalEquity: Double?
        let marketValue: Double?
        let dailyProfitLoss: Double?

        enum CodingKeys: String, CodingKey {
            case currency
            case cash
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
        let openPnl: Double?

        enum CodingKeys: String, CodingKey {
            case symbol
            case openQuantity
            case currentMarketValue
            case currentPrice
            case openPnl
        }
    }
}

struct QuestradeAccountsResponse: Decodable {
    let accounts: [Account]

    struct Account: Decodable, Identifiable {
        let number: String
        let type: String
        let status: String
        let isPrimary: Bool

        var id: String { number }
    }
}

struct AccountSnapshot: Equatable {
    let accountValue: Double
    let cash: Double
    let marketValue: Double
    let dailyChange: Double
    let openPnl: Double
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

        let openPnl = positions.positions.reduce(0.0) { $0 + ($1.openPnl ?? 0) }

        return AccountSnapshot(
            accountValue: primaryBalance.totalEquity ?? primaryBalance.marketValue ?? 0,
            cash: primaryBalance.cash ?? 0,
            marketValue: primaryBalance.marketValue ?? 0,
            dailyChange: primaryBalance.dailyProfitLoss ?? 0,
            openPnl: openPnl,
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

    func fetchAccounts() async throws -> [QuestradeAccountsResponse.Account] {
        let activeState = try await validState(forceRefresh: false)
        let response: QuestradeAccountsResponse = try await requestJSON(
            path: "/v1/accounts",
            state: activeState
        )
        return response.accounts
    }

    func fetchSnapshot(accountID: String) async throws -> AccountSnapshot {
        let activeState = try await validState(forceRefresh: false)
        let balances: QuestradeBalancesResponse = try await requestJSON(
            path: "/v1/accounts/\(accountID)/balances",
            state: activeState
        )
        let positions: QuestradePositionsResponse = try await requestJSON(
            path: "/v1/accounts/\(accountID)/positions",
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
        request.setValue("Bearer \(state.accessToken)", forHTTPHeaderField: "Authorization")

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
import AuthenticationServices

private let oauthCallbackScheme = "questrademacmenu"
private let oauthCallbackURL = "questrademacmenu://auth.app"

private final class AuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

@MainActor
final class SnapshotStore: ObservableObject {
    private static let refreshTokenKey = "questrade.refreshToken"
    private static let clientIDKey = "questrade.clientID"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }

    @Published private(set) var isAuthenticated = false
    @Published var accounts: [QuestradeAccountsResponse.Account] = []
    @Published var snapshots: [String: AccountSnapshot] = [:]
    @Published var selectedAccountIndex: Int = 0
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isLoginInProgress = false

    private var refreshToken: String {
        get { UserDefaults.standard.string(forKey: Self.refreshTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.refreshTokenKey) }
    }

    private var pollTask: Task<Void, Never>?
    private var client: QuestradeClient?
    private var activeConfig: QuestradeClient.Config?
    private var authSession: ASWebAuthenticationSession?
    private let contextProvider = AuthContextProvider()

    init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        isAuthenticated = !(UserDefaults.standard.string(forKey: Self.refreshTokenKey) ?? "").isEmpty
    }

    deinit {
        pollTask?.cancel()
    }

    var selectedAccount: QuestradeAccountsResponse.Account? {
        guard selectedAccountIndex < accounts.count else { return nil }
        return accounts[selectedAccountIndex]
    }

    var selectedSnapshot: AccountSnapshot? {
        guard let account = selectedAccount else { return nil }
        return snapshots[account.number]
    }

    func startOAuthLogin() {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            errorMessage = "Enter your Questrade API consumer key first."
            return
        }

        var components = URLComponents(string: "https://login.questrade.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: oauthCallbackURL)
        ]

        guard let authURL = components.url else { return }

        isLoginInProgress = true
        errorMessage = nil

        let handler: @Sendable (URL?, (any Error)?) -> Void = { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoginInProgress = false

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    self.errorMessage = "Login failed: \(error.localizedDescription)"
                    return
                }

                guard let callbackURL,
                      let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.errorMessage = "Login failed: no authorization code received."
                    return
                }

                await self.exchangeCodeForToken(code: code, clientID: trimmedClientID)
            }
        }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: oauthCallbackScheme,
            completionHandler: handler
        )

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func exchangeCodeForToken(code: String, clientID: String) async {
        isLoading = true
        defer { isLoading = false }

        var components = URLComponents(string: "https://login.questrade.com/oauth2/token")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: oauthCallbackURL)
        ]

        guard let tokenURL = components.url else { return }
        print("[Auth] Exchanging code at: \(tokenURL)")

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            print("[Auth] Token exchange status: \(httpResponse?.statusCode ?? -1)")
            print("[Auth] Token exchange body: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            guard let httpResponse, (200..<300).contains(httpResponse.statusCode) else {
                errorMessage = "Token exchange failed (HTTP \(httpResponse?.statusCode ?? -1))."
                return
            }

            let token = try JSONDecoder().decode(QuestradeTokenResponse.self, from: data)
            print("[Auth] Got token, api_server: \(token.apiServer)")
            refreshToken = token.refreshToken
            isAuthenticated = true
            startPolling()
        } catch {
            print("[Auth] Token exchange error: \(error)")
            errorMessage = "Token exchange failed: \(error.localizedDescription)"
        }
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
        let storedToken = refreshToken
        guard !storedToken.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let config = QuestradeClient.Config(
            refreshToken: storedToken,
            authTokenURL: URL(string: "https://login.questrade.com/oauth2/token")!
        )

        if config != activeConfig {
            client = QuestradeClient(config: config)
            activeConfig = config
        }

        guard let client else { return }
        let c = client

        if accounts.isEmpty {
            do {
                let fetched = try await c.fetchAccounts()
                accounts = fetched.filter { $0.status == "Active" }
            } catch {
                errorMessage = "Failed to fetch accounts: \(error.localizedDescription)"
                return
            }
        }

        let accountNumbers = accounts.map(\.number)
        await withTaskGroup(of: (String, AccountSnapshot?).self) { group in
            for number in accountNumbers {
                group.addTask {
                    let snap = try? await c.fetchSnapshot(accountID: number)
                    return (number, snap)
                }
            }
            for await (number, snapshot) in group {
                if let snapshot {
                    snapshots[number] = snapshot
                }
            }
        }

        lastUpdated = Date()
        errorMessage = nil
    }

    func logout() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        activeConfig = nil
        snapshots = [:]
        accounts = []
        selectedAccountIndex = 0
        lastUpdated = nil
        errorMessage = nil
        refreshToken = ""
        isAuthenticated = false
    }

    var menuBarTitle: String {
        guard let snapshot = selectedSnapshot else { return "Questrade" }
        return formatCurrency(snapshot.accountValue, currency: snapshot.currency)
    }

    func formatCurrency(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func formatChange(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        formatter.positivePrefix = formatter.plusSign
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

@main
struct questrade_mac_menu: App {
    @StateObject private var store = SnapshotStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Text(store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarView: View {
    @ObservedObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.isAuthenticated {
                loginView
            } else {
                mainView
            }
        }
        .padding(12)
        .frame(minWidth: 320)
        .task {
            if store.isAuthenticated {
                store.startPolling()
            }
        }
    }

    @ViewBuilder
    private var loginView: some View {
        Text("Questrade")
            .font(.headline)

        if let error = store.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        TextField("Consumer Key (from API Centre)", text: $store.clientID)
            .textFieldStyle(.roundedBorder)

        Button {
            store.startOAuthLogin()
        } label: {
            if store.isLoginInProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Logging in…")
                }
            } else {
                Text("Login with Questrade")
            }
        }
        .disabled(store.isLoginInProgress || store.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderedProminent)

        Text("Get your consumer key from Questrade → API Centre → Register a personal app")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var mainView: some View {
        if store.accounts.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading accounts…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            accountCarousel
        }

        if let error = store.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Divider()

        HStack {
            Button("Reload") {
                Task { await store.reload() }
            }
            .disabled(store.isLoading)

            if store.isLoading {
                ProgressView().controlSize(.mini)
            }

            if let lastUpdated = store.lastUpdated {
                Text(lastUpdated.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button("Logout") { store.logout() }
        }
    }

    @ViewBuilder
    private var accountCarousel: some View {
        let idx = store.selectedAccountIndex
        let count = store.accounts.count

        VStack(spacing: 6) {
            HStack(alignment: .center) {
                Button { store.selectedAccountIndex -= 1 } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(idx == 0)
                .opacity(idx == 0 ? 0.3 : 1)

                Spacer()

                if let account = store.selectedAccount {
                    VStack(spacing: 2) {
                        Text("\(account.type.uppercased()) – \(account.number)")
                            .font(.headline)
                        Text("Self-directed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button { store.selectedAccountIndex += 1 } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(idx >= count - 1)
                .opacity(idx >= count - 1 ? 0.3 : 1)
            }

            if count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { i in
                        Circle()
                            .fill(i == idx ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
            }

            if let snapshot = store.selectedSnapshot {
                snapshotView(snapshot)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func snapshotView(_ snapshot: AccountSnapshot) -> some View {
        VStack(spacing: 3) {
            balanceRow("Total equity", value: snapshot.accountValue, currency: snapshot.currency)
            balanceRow("Cash", value: snapshot.cash, currency: snapshot.currency)
            balanceRow("Market value", value: snapshot.marketValue, currency: snapshot.currency)
            Divider().padding(.vertical, 2)
            changeRow("Open P&L", value: snapshot.openPnl, currency: snapshot.currency)
            changeRow("Today's P&L", value: snapshot.dailyChange, currency: snapshot.currency)
        }
    }

    private func balanceRow(_ label: String, value: Double, currency: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(store.formatCurrency(value, currency: currency)).monospacedDigit()
        }
        .font(.callout)
    }

    private func changeRow(_ label: String, value: Double, currency: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(store.formatChange(value, currency: currency))
                .monospacedDigit()
                .foregroundStyle(value >= 0 ? .green : .red)
        }
        .font(.callout)
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
