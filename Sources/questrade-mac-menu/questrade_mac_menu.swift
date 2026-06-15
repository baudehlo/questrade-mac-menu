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
    let sodCombinedBalances: [CombinedBalance]
    let perCurrencyBalances: [CombinedBalance]

    // Memberwise init — perCurrencyBalances defaults to [] for tests/previews
    init(
        combinedBalances: [CombinedBalance],
        sodCombinedBalances: [CombinedBalance],
        perCurrencyBalances: [CombinedBalance] = []
    ) {
        self.combinedBalances = combinedBalances
        self.sodCombinedBalances = sodCombinedBalances
        self.perCurrencyBalances = perCurrencyBalances
    }

    // Custom decoder so perCurrencyBalances defaults to [] when absent in JSON
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combinedBalances    = try c.decode([CombinedBalance].self, forKey: .combinedBalances)
        sodCombinedBalances = try c.decode([CombinedBalance].self, forKey: .sodCombinedBalances)
        perCurrencyBalances = try c.decodeIfPresent([CombinedBalance].self, forKey: .perCurrencyBalances) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case combinedBalances, sodCombinedBalances, perCurrencyBalances
    }

    struct CombinedBalance: Decodable {
        let currency: String
        let cash: Double?
        let totalEquity: Double?
        let marketValue: Double?
        let isRealTime: Bool?
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
    struct CurrencyData: Equatable {
        let currency: String
        let accountValue: Double
        let cash: Double
        let marketValue: Double
        let dailyChange: Double
        let openPnl: Double
    }

    let topPositions: [QuestradePositionsResponse.Position]
    let currencyData: [String: CurrencyData]   // keyed by currency code
    let availableCurrencies: [String]           // ordered: highest equity first

    // Convenience: data for a chosen currency, defaulting to highest-equity one
    func data(for currency: String) -> CurrencyData? { currencyData[currency] }
    var primaryCurrency: String { availableCurrencies.first ?? "CAD" }

    static func build(
        balances: QuestradeBalancesResponse,
        positions: QuestradePositionsResponse,
        topLimit: Int = 5,
        now: Date = Date()
    ) -> AccountSnapshot? {
        guard !balances.combinedBalances.isEmpty else { return nil }

        let sortedBalances = balances.combinedBalances
            .sorted { ($0.totalEquity ?? 0) > ($1.totalEquity ?? 0) }

        let sortedPositions = positions.positions
            .sorted { abs($0.currentMarketValue) > abs($1.currentMarketValue) }

        // Sum position openPnl — values are in the positions' own currency (USD for
        // US-listed stocks). We derive an implied secondary→primary FX rate from
        // perCurrencyBalances vs combinedBalances to convert correctly.
        let positionOpenPnl = positions.positions.reduce(0.0) { $0 + ($1.openPnl ?? 0) }

        let primaryBalance = sortedBalances[0]
        let primaryPerCurrencyMV = balances.perCurrencyBalances
            .first { $0.currency == primaryBalance.currency }?.marketValue ?? 0
        let secondaryPerCurrencyMV = balances.perCurrencyBalances
            .filter { $0.currency != primaryBalance.currency }
            .reduce(0.0) { $0 + ($1.marketValue ?? 0) }
        // rate converts secondary-currency (USD) amounts into the primary currency (CAD)
        let impliedRate: Double = secondaryPerCurrencyMV > 0
            ? ((primaryBalance.marketValue ?? 0) - primaryPerCurrencyMV) / secondaryPerCurrencyMV
            : 1.0

        // On non-trading days (weekends/holidays), sodCombinedBalances reflects
        // the previous session's SOD — not the current day's opening — so the
        // subtraction yields the *previous* session's P&L instead of today's.
        // Use Eastern time (market timezone) to detect weekends, and also check
        // isRealTime as a secondary signal for mid-week holidays.
        var easternCalendar = Calendar(identifier: .gregorian)
        easternCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let isWeekend = easternCalendar.isDateInWeekend(now)
        let anyRealTime = balances.combinedBalances.contains { $0.isRealTime == true }
        let isMarketDay = !isWeekend && anyRealTime

        var currencyData: [String: AccountSnapshot.CurrencyData] = [:]
        for balance in sortedBalances {
            let currentEquity = balance.totalEquity ?? balance.marketValue ?? 0
            let sodBalance = balances.sodCombinedBalances
                .first { $0.currency == balance.currency }
            let sodEquity = sodBalance?.totalEquity ?? sodBalance?.marketValue ?? currentEquity
            let dailyChange = isMarketDay ? currentEquity - sodEquity : 0.0
            // Primary currency: positions are in secondary currency, apply implied rate.
            // Secondary currency: positions are already denominated in that currency.
            let openPnl = balance.currency == primaryBalance.currency
                ? positionOpenPnl * impliedRate
                : positionOpenPnl

            currencyData[balance.currency] = AccountSnapshot.CurrencyData(
                currency: balance.currency,
                accountValue: currentEquity,
                cash: balance.cash ?? 0,
                marketValue: balance.marketValue ?? 0,
                dailyChange: dailyChange,
                openPnl: openPnl
            )
        }

        return AccountSnapshot(
            topPositions: Array(sortedPositions.prefix(topLimit)),
            currencyData: currencyData,
            availableCurrencies: sortedBalances.map(\.currency)
        )
    }
}

enum QuestradeClientError: LocalizedError {
    case invalidAuthURL
    case invalidEndpoint
    case invalidResponse
    case missingSnapshotData
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL:         return "Could not build the authentication URL."
        case .invalidEndpoint:        return "Could not build the API request URL."
        case .invalidResponse:        return "Unexpected response from Questrade API."
        case .missingSnapshotData:    return "Account returned no balance data."
        case .authenticationRequired: return "Session expired. Please log in again."
        }
    }
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
    private let onTokenRotated: @Sendable (String) -> Void
    private var state: SessionState?

    init(
        config: Config,
        session: URLSession = .shared,
        onTokenRotated: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.session = session
        self.onTokenRotated = onTokenRotated
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
            if let httpResponse = response as? HTTPURLResponse,
               (400..<500).contains(httpResponse.statusCode) {
                throw QuestradeClientError.authenticationRequired
            }
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
        onTokenRotated(token.refreshToken)
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
    nonisolated static let refreshTokenKey = "questrade.refreshToken"
    private static let clientIDKey = "questrade.clientID"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }

    @Published private(set) var isAuthenticated = false
    @Published var accounts: [QuestradeAccountsResponse.Account] = []
    @Published var snapshots: [String: AccountSnapshot] = [:]
    @Published var selectedAccountIndex: Int = 0
    @Published var selectedCurrency: String = "CAD"
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

    private var authSession: ASWebAuthenticationSession?
    private let contextProvider = AuthContextProvider()

    init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        isAuthenticated = !(UserDefaults.standard.string(forKey: Self.refreshTokenKey) ?? "").isEmpty
        if isAuthenticated {
            startPolling()
        }
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

        if client == nil {
            client = QuestradeClient(config: config, onTokenRotated: { newToken in
                // Write directly — UserDefaults is thread-safe and this must be
                // synchronous so the token is never lost if the process terminates
                // between rotation and an async MainActor task executing.
                UserDefaults.standard.set(newToken, forKey: SnapshotStore.refreshTokenKey)
            })
        }

        guard let client else { return }
        let c = client

        if accounts.isEmpty {
            do {
                let fetched = try await c.fetchAccounts()
                accounts = fetched.filter { $0.status == "Active" }
            } catch {
                self.client = nil
                handleReloadError(error)
                return
            }
        }

        let accountNumbers = accounts.map(\.number)
        var anySucceeded = false
        var firstError: Error?
        await withTaskGroup(of: (String, Result<AccountSnapshot, Error>).self) { group in
            for number in accountNumbers {
                group.addTask {
                    do {
                        let snap = try await c.fetchSnapshot(accountID: number)
                        return (number, .success(snap))
                    } catch {
                        return (number, .failure(error))
                    }
                }
            }
            for await (number, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[number] = snapshot
                    anySucceeded = true
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
        }

        if anySucceeded {
            lastUpdated = Date()
            // Only surface an error when every account failed; a single failing
            // secondary account is not worth alarming the user about.
            errorMessage = nil
        } else if let error = firstError {
            self.client = nil
            handleReloadError(error)
        }
    }

    private func handleReloadError(_ error: Error) {
        if let qtError = error as? QuestradeClientError,
           case .authenticationRequired = qtError {
            // Refresh token is expired/revoked — drop back to login screen
            // (preserves clientID so the user just needs to click Login again)
            accounts = []
            snapshots = [:]
            isAuthenticated = false
            errorMessage = "Session expired. Please log in again."
        } else {
            errorMessage = "Failed to update portfolio: \(error.localizedDescription)"
        }
    }

    func logout() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        snapshots = [:]
        accounts = []
        selectedAccountIndex = 0
        lastUpdated = nil
        errorMessage = nil
        refreshToken = ""
        isAuthenticated = false
    }

    var menuBarTitle: String {
        guard let snapshot = selectedSnapshot,
              let d = snapshot.data(for: selectedCurrency) ?? snapshot.data(for: snapshot.primaryCurrency)
        else { return "Questrade" }
        return formatCurrency(d.accountValue, currency: d.currency)
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

// Renders the menu bar label as an NSImage so coloured text (green/red P&L)
// actually shows up — foregroundStyle on Text inside MenuBarExtra labels is
// silently ignored by the system.
private enum MenuBarLabel {
    static func image(value: String, change: String, positive: Bool) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let changeColor: NSColor = positive ? .systemGreen : .systemRed

        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let changeAttr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: changeColor,
        ]

        let full = NSMutableAttributedString(string: value + "  ", attributes: valueAttr)
        full.append(NSAttributedString(string: change, attributes: changeAttr))

        let size = full.size()
        let image = NSImage(size: size, flipped: false) { rect in
            full.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

@main
struct questrade_mac_menu: App {
    @StateObject private var store = SnapshotStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            if let snapshot = store.selectedSnapshot,
               let d = snapshot.data(for: store.selectedCurrency) ?? snapshot.data(for: snapshot.primaryCurrency) {
                Image(nsImage: MenuBarLabel.image(
                    value: store.formatCurrency(d.accountValue, currency: d.currency),
                    change: store.formatChange(d.dailyChange, currency: d.currency),
                    positive: d.dailyChange >= 0
                ))
            } else {
                Text(store.menuBarTitle)
            }
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
            HStack(alignment: .top, spacing: 4) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    store.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
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
        let currencies = snapshot.availableCurrencies
        let activeCurrency = currencies.contains(store.selectedCurrency)
            ? store.selectedCurrency
            : snapshot.primaryCurrency

        VStack(spacing: 6) {
            if currencies.count > 1 {
                Picker("Currency", selection: $store.selectedCurrency) {
                    ForEach(currencies, id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let d = snapshot.data(for: activeCurrency) {
                VStack(spacing: 3) {
                    balanceRow("Total equity", value: d.accountValue, currency: d.currency)
                    balanceRow("Cash", value: d.cash, currency: d.currency)
                    balanceRow("Market value", value: d.marketValue, currency: d.currency)
                    Divider().padding(.vertical, 2)
                    changeRow("Open P&L", value: d.openPnl, currency: d.currency)
                    changeRow("Today's P&L", value: d.dailyChange, currency: d.currency)
                }
            }
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
