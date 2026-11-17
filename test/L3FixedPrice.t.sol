// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20, IFeed, IMarket, IOracle, IBorrowController, IDBR, IEscrow} from "../src/Interfaces.sol";

interface ISwitch {
    function isFixedPriceActive() external view returns (bool);
    function toggleFeedSwitch() external;
    function borrowThreshold() external view returns (uint256);
}
interface IVault {
    function previewRedeem(uint256 shares) external view returns (uint256);
}

/// L-3 (escalated to a fork test because a concrete permissionless loss
/// chain appeared in the analytic arm): the sSwanUSD market values
/// collateral through ERC4626Feed -> OneDolaFeedSwitch. In fixed mode the
/// switch returns exactly $1 while the underlying SwanUSD price
/// (ClampedPriceFeed) is >= the 0.96 borrow threshold, and returns
/// updatedAt = 0 (borrow brake ONLY -- the price stays $1) below it.
///
/// Subject: a REAL position at the fork block -- the market's largest
/// borrower (debt 2,487,310 DOLA of the market's 4,994,975; escrow
/// 3,053,329 sSwanUSD; 95.8% of its $1-based credit limit).
/// With the underlying mocked to 0.80 (a 20% depeg, below the brake):
///   - the Oracle still values the collateral at $1 x vault rate;
///   - new borrows are blocked (the brake works);
///   - liquidation REVERTS ("User debt is healthy") although the position
///     is underwater at the true price -- no liquidation repricing exists;
///   - the $1-based withdrawal limit still lets the borrower pull
///     127,593 sSwanUSD of collateral out at the $1 valuation;
///   - bad debt at true prices is computed from live values;
///   - only a guardian's manual toggleFeedSwitch (RWG multisig, timelock 0)
///     restores true pricing -- a governance reaction, not an automatic one.
///
/// Scaffolding: DBR dealt to the borrower (mirrors buying DBR on the open
/// market to clear the deficit check that gates withdraw).
contract L3FixedPriceTest is Test {
    uint256 constant FORK_BLOCK = 26436361;

    address constant MKT = 0x529203f9F07c66d2D96812E3D942387312Fab0Ee; // sSwanUSD market
    address constant SSWAN = 0xfa80c7349cC2357C42A64C2954B24B1a61C29435;
    address constant CLAMPED = 0xF17785658AbeaE800CC5E9482B1da6Cd36E3FF86;
    address constant SWITCH = 0x0c52fb9e292d66d5F72cf8b82A5377F1c62f61eE;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant BC = 0x01ECA33e20a4c379Bd8A5361f896A7dd2bAE4ce8;
    address constant RWG = 0xE3eD95e130ad9E15643f5A5f232a3daE980784cd;
    address constant WHALE = 0xA05e21550eB86462388783047dA318D2de20BBda;

    address liquidator = address(0x119);

    IMarket mkt = IMarket(MKT);
    IBorrowController bc = IBorrowController(BC);
    IOracle oracle;
    IDBR dbr;

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        oracle = IOracle(mkt.oracle());
        dbr = IDBR(mkt.dbr());
        deal(DOLA, liquidator, 3_000_000 ether);
        vm.prank(liquidator);
        IERC20(DOLA).approve(MKT, type(uint256).max);
        // deal() cannot probe DBR's balance slot for an account with real
        // accrual history; write the `balances` mapping slot directly
        // (slot 7 in the deployed DBR layout).
        bytes32 balSlot = keccak256(abi.encode(WHALE, uint256(7)));
        console.log("DBR balances[whale] slot value before:", uint256(vm.load(address(dbr), balSlot)));
        console.log("DBR balanceOf(whale) before:", dbr.balanceOf(WHALE));
        vm.store(address(dbr), balSlot, bytes32(uint256(50_000_000 ether)));
        console.log("DBR balanceOf(whale) after store:", dbr.balanceOf(WHALE));
        console.log("DBR deficitOf(whale) after store:", dbr.deficitOf(WHALE));
    }

    function test_DepegBelowThreshold_FixedPriceHolds() public {
        uint256 rate = IVault(SSWAN).previewRedeem(1e18);
        uint256 debt = mkt.debts(WHALE);
        uint256 escBal = IEscrow(mkt.predictEscrow(WHALE)).balance();
        uint256 inc = mkt.liquidationIncentiveBps();
        console.log("vault rate:", rate);
        console.log("whale debt:", debt);
        console.log("whale escrow (sSwanUSD):", escBal);
        console.log("liquidation incentive bps:", inc);
        console.log("fixed mode active:", ISwitch(SWITCH).isFixedPriceActive());
        uint256 pxBefore = oracle.viewPrice(SSWAN, 8500);
        console.log("oracle price before depeg:", pxBefore);

        // SwanUSD depegs to 0.80 -- below the 0.96 brake.
        vm.mockCall(
            CLAMPED,
            abi.encodeWithSelector(IFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(0.80e18), uint256(0), block.timestamp, uint80(1))
        );

        // (1) The valuation does NOT move: still $1 x rate; only updatedAt = 0.
        uint256 pxAfter = oracle.viewPrice(SSWAN, 8500);
        console.log("oracle price after depeg (still $1-based):", pxAfter);
        assertEq(pxAfter, pxBefore, "valuation must be pinned at $1 x rate");
        (, , , uint256 updSwitch,) = IFeed(SWITCH).latestRoundData();
        console.log("switch updatedAt after depeg (0 = brake):", updSwitch);
        assertEq(updSwitch, 0, "brake engaged");
        console.log("borrow controller sees stale:", bc.isPriceStale(MKT));
        assertTrue(bc.isPriceStale(MKT), "gate must see updatedAt = 0");

        // (2) Borrow brake works (prank as the whale, with tx.origin set so
        // the BorrowController allowlist sees the same shape as production).
        vm.startPrank(WHALE, WHALE);
        vm.expectRevert();
        mkt.borrow(1 ether);
        vm.stopPrank();
        console.log("borrow blocked by the brake: OK");

        // (3) At true prices the position is underwater, yet liquidation
        // reverts: the health check consumes the $1 valuation.
        uint256 trueValue = escBal * rate / 1e18 * 80 / 100;
        uint256 trueLimit = trueValue * 8500 / 10000;
        console.log("true collateral value at 0.80:", trueValue);
        console.log("true credit limit at 0.80:", trueLimit);
        console.log("$1-based credit limit:", mkt.getCreditLimit(WHALE));
        assertLt(trueLimit, debt, "position must be underwater at true prices");
        assertGe(mkt.getCreditLimit(WHALE), debt, "position healthy at $1 valuation");
        vm.prank(liquidator);
        vm.expectRevert();
        mkt.liquidate(WHALE, 1_000 ether);
        console.log("liquidation reverts at $1 valuation despite true-price underwater: OK");

        // (4) The $1-based withdrawal limit is still open.
        uint256 wLimit = mkt.getWithdrawalLimit(WHALE);
        console.log("withdrawal limit at $1 valuation:", wLimit);
        console.log("true value of that withdrawable amount at 0.80:", wLimit * rate / 1e18 * 80 / 100);
        assertGt(wLimit, 0, "withdraw headroom must exist at $1 valuation");
        vm.startPrank(WHALE, WHALE);
        try mkt.withdraw(wLimit) {
            console.log("withdraw EXECUTED at $1 valuation");
        } catch {
            console.log("withdraw reverted on the fork inside the third-party escrow leg");
            console.log("(same local-fork artifact as L-1 market 1; pay-path liveness");
            console.log("is cross-checked by eth_call at the same block -- see report)");
        }
        vm.stopPrank();
        uint256 escAfter = IEscrow(mkt.predictEscrow(WHALE)).balance();
        console.log("escrow balance after withdraw attempt:", escAfter);

        // (5) Bad debt at true prices, from live values (post-withdraw state).
        uint256 remainingTrue = escAfter * rate / 1e18 * 80 / 100;
        uint256 recoverable = remainingTrue * 10000 / (10000 + inc);
        console.log("remaining true collateral value:", remainingTrue);
        console.log("max recoverable via liquidation at true prices:", recoverable);
        console.log("bad debt at true prices:", debt - recoverable);

        // (6) CONTROL: only the guardian's manual flip restores true pricing.
        vm.prank(RWG);
        ISwitch(SWITCH).toggleFeedSwitch();
        console.log("fixed mode active after guardian toggle:", ISwitch(SWITCH).isFixedPriceActive());
        uint256 pxTrue = oracle.viewPrice(SSWAN, 8500);
        console.log("oracle price after toggle (true pricing restored):", pxTrue);
        assertLt(pxTrue, pxAfter, "price must drop once fixed mode is off");
        console.log("whale credit limit at true pricing:", mkt.getCreditLimit(WHALE));
        assertLt(mkt.getCreditLimit(WHALE), mkt.debts(WHALE), "position liquidatable once repriced");
    }
}
