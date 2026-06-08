import Foundation
import Testing
@testable import questrade_mac_menu

@Test
func buildsSnapshotFromBalancesAndPositions() throws {
    let balancesJSON = """
    {
      "combinedBalances": [
        {
          "currency": "CAD",
          "totalEquity": 10500.55,
          "dailyProfitLoss": 125.10
        }
      ]
    }
    """.data(using: .utf8)!

    let positionsJSON = """
    {
      "positions": [
        { "symbol": "SHOP", "openQuantity": 3, "currentMarketValue": 1500.0, "currentPrice": 500.0 },
        { "symbol": "AAPL", "openQuantity": 5, "currentMarketValue": 1200.0, "currentPrice": 240.0 },
        { "symbol": "NVDA", "openQuantity": 1, "currentMarketValue": 900.0, "currentPrice": 900.0 }
      ]
    }
    """.data(using: .utf8)!

    let balances = try JSONDecoder().decode(QuestradeBalancesResponse.self, from: balancesJSON)
    let positions = try JSONDecoder().decode(QuestradePositionsResponse.self, from: positionsJSON)

    let snapshot = AccountSnapshot.build(balances: balances, positions: positions)

    #expect(snapshot?.currency == "CAD")
    #expect(snapshot?.accountValue == 10500.55)
    #expect(snapshot?.dailyChange == 125.10)
    #expect(snapshot?.topPositions.map(\.symbol) == ["SHOP", "AAPL", "NVDA"])
}

@Test
func emptyBalancesReturnNoSnapshot() {
    let balances = QuestradeBalancesResponse(combinedBalances: [])
    let positions = QuestradePositionsResponse(positions: [])

    let snapshot = AccountSnapshot.build(balances: balances, positions: positions)

    #expect(snapshot == nil)
}
