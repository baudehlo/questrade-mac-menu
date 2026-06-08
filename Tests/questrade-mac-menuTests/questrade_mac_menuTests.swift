import Foundation
import Testing
@testable import questrade_mac_menu

@Suite struct JSONDecodingTests {

    private let decoder = JSONDecoder()

    // MARK: - QuestradeTokenResponse

    @Test func decodesTokenResponseSnakeCase() throws {
        let json = """
        {
          "access_token": "abc123",
          "refresh_token": "def456",
          "api_server": "https://api01.iq.questrade.com/",
          "token_type": "Bearer",
          "expires_in": 1800
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradeTokenResponse.self, from: json)

        #expect(response.accessToken == "abc123")
        #expect(response.refreshToken == "def456")
        #expect(response.apiServer.absoluteString == "https://api01.iq.questrade.com/")
        #expect(response.tokenType == "Bearer")
        #expect(response.expiresIn == 1800)
    }

    // MARK: - QuestradeBalancesResponse

    @Test func decodesBalancesWithAllFields() throws {
        let json = """
        {
          "combinedBalances": [
            {
              "currency": "CAD",
              "cash": 1234.56,
              "totalEquity": 50000.0,
              "marketValue": 48765.44,
              "dailyProfitLoss": 320.75
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradeBalancesResponse.self, from: json)

        #expect(response.combinedBalances.count == 1)
        let b = response.combinedBalances[0]
        #expect(b.currency == "CAD")
        #expect(b.cash == 1234.56)
        #expect(b.totalEquity == 50000.0)
        #expect(b.marketValue == 48765.44)
        #expect(b.dailyProfitLoss == 320.75)
    }

    @Test func decodesBalancesWithMissingOptionals() throws {
        let json = #"{"combinedBalances": [{"currency": "USD"}]}"#.data(using: .utf8)!

        let response = try decoder.decode(QuestradeBalancesResponse.self, from: json)
        let b = response.combinedBalances[0]

        #expect(b.currency == "USD")
        #expect(b.cash == nil)
        #expect(b.totalEquity == nil)
        #expect(b.marketValue == nil)
        #expect(b.dailyProfitLoss == nil)
    }

    @Test func decodesMultipleCombinedBalances() throws {
        let json = """
        {
          "combinedBalances": [
            {"currency": "CAD", "totalEquity": 10000.0},
            {"currency": "USD", "totalEquity": 5000.0}
          ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradeBalancesResponse.self, from: json)
        #expect(response.combinedBalances.count == 2)
        #expect(response.combinedBalances[0].currency == "CAD")
        #expect(response.combinedBalances[1].currency == "USD")
    }

    // MARK: - QuestradePositionsResponse

    @Test func decodesPositionWithAllFields() throws {
        let json = """
        {
          "positions": [
            {
              "symbol": "SHOP",
              "openQuantity": 10.0,
              "currentMarketValue": 5000.0,
              "currentPrice": 500.0,
              "openPnl": 250.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradePositionsResponse.self, from: json)

        #expect(response.positions.count == 1)
        let p = response.positions[0]
        #expect(p.symbol == "SHOP")
        #expect(p.openQuantity == 10.0)
        #expect(p.currentMarketValue == 5000.0)
        #expect(p.currentPrice == 500.0)
        #expect(p.openPnl == 250.0)
    }

    @Test func decodesPositionWithNilOptionals() throws {
        let json = """
        {
          "positions": [
            {"symbol": "AAPL", "openQuantity": 5.0, "currentMarketValue": 1200.0}
          ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradePositionsResponse.self, from: json)
        let p = response.positions[0]

        #expect(p.currentPrice == nil)
        #expect(p.openPnl == nil)
    }

    @Test func decodesEmptyPositions() throws {
        let json = #"{"positions": []}"#.data(using: .utf8)!
        let response = try decoder.decode(QuestradePositionsResponse.self, from: json)
        #expect(response.positions.isEmpty)
    }

    // MARK: - QuestradeAccountsResponse

    @Test func decodesAccounts() throws {
        let json = """
        {
          "accounts": [
            {"number": "12345678", "type": "TFSA", "status": "Active", "isPrimary": true},
            {"number": "87654321", "type": "RRSP", "status": "Active", "isPrimary": false}
          ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradeAccountsResponse.self, from: json)

        #expect(response.accounts.count == 2)
        let first = response.accounts[0]
        #expect(first.number == "12345678")
        #expect(first.type == "TFSA")
        #expect(first.status == "Active")
        #expect(first.isPrimary)
        #expect(!response.accounts[1].isPrimary)
    }

    @Test func accountIdMatchesNumber() throws {
        let json = """
        {
          "accounts": [
            {"number": "99887766", "type": "MARGIN", "status": "Active", "isPrimary": false}
          ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(QuestradeAccountsResponse.self, from: json)
        #expect(response.accounts[0].id == "99887766")
    }
}

// MARK: -

@Suite struct AccountSnapshotBuildTests {

    // MARK: - Nil guard

    @Test func buildReturnsNilForEmptyBalances() {
        let balances = QuestradeBalancesResponse(combinedBalances: [])
        let positions = QuestradePositionsResponse(positions: [])
        #expect(AccountSnapshot.build(balances: balances, positions: positions) == nil)
    }

    // MARK: - Field mapping

    @Test func buildExtractsAllFields() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: 500.0, totalEquity: 10500.55,
            marketValue: 10000.55, dailyProfitLoss: 125.10
        ))
        let positions = QuestradePositionsResponse(positions: [
            position(symbol: "SHOP", marketValue: 1500.0, openPnl:  100.0),
            position(symbol: "AAPL", marketValue: 1200.0, openPnl:  -30.0),
        ])

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions))

        #expect(snapshot.currency == "CAD")
        #expect(snapshot.accountValue == 10500.55)
        #expect(snapshot.cash == 500.0)
        #expect(snapshot.marketValue == 10000.55)
        #expect(snapshot.dailyChange == 125.10)
        #expect(abs(snapshot.openPnl - 70.0) < 0.001)
    }

    @Test func buildUsesTotalEquityOverMarketValueForAccountValue() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 9999.0,
            marketValue: 8000.0, dailyProfitLoss: nil
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.accountValue == 9999.0)
    }

    @Test func buildFallsBackToMarketValueWhenTotalEquityIsNil() throws {
        let balances = try decode(balancesJSON(
            currency: "USD", cash: nil, totalEquity: nil,
            marketValue: 7500.0, dailyProfitLoss: nil
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.accountValue == 7500.0)
    }

    @Test func buildDefaultsCashToZeroWhenNil() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.cash == 0.0)
    }

    @Test func buildDefaultsMarketValueToZeroWhenNil() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.marketValue == 0.0)
    }

    @Test func buildDefaultsDailyChangeToZeroWhenNil() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.dailyChange == 0.0)
    }

    // MARK: - Open P&L

    @Test func buildSumsOpenPnlFromPositions() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))
        let positions = QuestradePositionsResponse(positions: [
            position(symbol: "A", marketValue: 1000.0, openPnl:  200.0),
            position(symbol: "B", marketValue:  800.0, openPnl:  -75.0),
            position(symbol: "C", marketValue:  600.0, openPnl:   25.0),
        ])

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions))

        #expect(abs(snapshot.openPnl - 150.0) < 0.001)
    }

    @Test func buildTreatsNilOpenPnlAsZero() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))
        let positions = QuestradePositionsResponse(positions: [
            position(symbol: "A", marketValue: 1000.0, openPnl:  100.0),
            position(symbol: "B", marketValue:  800.0, openPnl:  nil),   // nil → 0
            position(symbol: "C", marketValue:  600.0, openPnl:  -50.0),
        ])

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions))

        #expect(abs(snapshot.openPnl - 50.0) < 0.001)
    }

    @Test func buildOpenPnlIsZeroWithEmptyPositions() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.openPnl == 0.0)
    }

    // MARK: - Top positions sorting and limiting

    @Test func buildSortsPositionsByMarketValueDescending() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))
        let positions = QuestradePositionsResponse(positions: [
            position(symbol: "SMALL",  marketValue:  100.0, openPnl: nil),
            position(symbol: "LARGE",  marketValue: 3000.0, openPnl: nil),
            position(symbol: "MEDIUM", marketValue: 1500.0, openPnl: nil),
        ])

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions))

        #expect(snapshot.topPositions.map(\.symbol) == ["LARGE", "MEDIUM", "SMALL"])
    }

    @Test func buildDefaultsTopLimitToFive() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))
        let positions = QuestradePositionsResponse(
            positions: (1...8).map { position(symbol: "S\($0)", marketValue: Double($0) * 100, openPnl: nil) }
        )

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions))

        #expect(snapshot.topPositions.count == 5)
    }

    @Test func buildRespectsCustomTopLimit() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))
        let positions = QuestradePositionsResponse(
            positions: (1...6).map { position(symbol: "S\($0)", marketValue: Double($0) * 100, openPnl: nil) }
        )

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions, topLimit: 3))

        #expect(snapshot.topPositions.count == 3)
    }

    @Test func buildWithFewerPositionsThanLimit() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: nil, totalEquity: 5000.0,
            marketValue: nil, dailyProfitLoss: nil
        ))
        let positions = QuestradePositionsResponse(positions: [
            position(symbol: "ONLY", marketValue: 500.0, openPnl: nil),
        ])

        let snapshot = try #require(AccountSnapshot.build(balances: balances, positions: positions))

        #expect(snapshot.topPositions.count == 1)
        #expect(snapshot.topPositions[0].symbol == "ONLY")
    }

    @Test func buildWithEmptyPositionsHasNoTopPositions() throws {
        let balances = try decode(balancesJSON(
            currency: "CAD", cash: 1000.0, totalEquity: 1000.0,
            marketValue: nil, dailyProfitLoss: 0.0
        ))

        let snapshot = try #require(AccountSnapshot.build(
            balances: balances, positions: .init(positions: [])
        ))

        #expect(snapshot.topPositions.isEmpty)
    }

    // MARK: - Helpers

    private func decode(_ data: Data) throws -> QuestradeBalancesResponse {
        try JSONDecoder().decode(QuestradeBalancesResponse.self, from: data)
    }

    private func balancesJSON(
        currency: String,
        cash: Double?,
        totalEquity: Double?,
        marketValue: Double?,
        dailyProfitLoss: Double?
    ) -> Data {
        var fields = [#""currency": "\#(currency)""#]
        if let v = cash            { fields.append(#""cash": \#(v)"#) }
        if let v = totalEquity     { fields.append(#""totalEquity": \#(v)"#) }
        if let v = marketValue     { fields.append(#""marketValue": \#(v)"#) }
        if let v = dailyProfitLoss { fields.append(#""dailyProfitLoss": \#(v)"#) }
        return #"{"combinedBalances": [{\#(fields.joined(separator: ", "))}]}"#
            .data(using: .utf8)!
    }

    private func position(
        symbol: String,
        marketValue: Double,
        openPnl: Double?
    ) -> QuestradePositionsResponse.Position {
        QuestradePositionsResponse.Position(
            symbol: symbol,
            openQuantity: 1,
            currentMarketValue: marketValue,
            currentPrice: nil,
            openPnl: openPnl
        )
    }
}

