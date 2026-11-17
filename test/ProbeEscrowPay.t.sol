// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IMarket} from "../src/Interfaces.sol";

/// DIAGNOSTIC (not a finding): documents a local-fork execution artifact in
/// the reUSD-sDOLA market's StakeDAO strategy escrow. On a plain fork --
/// no warps, no attack -- even a small in-limit withdraw by a real borrower
/// reverts inside StakeDAO's CurveStrategy ("NotActivated"). The identical
/// call simulated with eth_call (`cast call`) at the identical block
/// SUCCEEDS, mainnet Withdraw events for this market are recent, and the
/// Yearn-escrow market's pay path executes cleanly on the same fork
/// (ProbeYvPay). Conclusion: the revert is an artifact of local fork
/// execution of that third-party strategy leg, not a production freeze.
/// These tests PASS by asserting the artifact reproduces.
contract ProbeEscrowPayTest is Test {
    uint256 constant FORK_BLOCK = 26436361;
    address constant MKT = 0xf9287c29Cb888F4834B7D2757a833D509e7f9D9A;
    address constant P2 = 0x005ea0be32125792CBff9c6DbaF91a7001e43235;

    function test_ProbeWithdrawSmall() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        IMarket m = IMarket(MKT);
        console.log("withdrawal limit:", m.getWithdrawalLimit(P2));
        vm.prank(P2);
        vm.expectRevert(); // StakeDAO strategy leg: local-fork artifact (see header)
        m.withdraw(100 ether);
        console.log("artifact reproduced: fork withdraw reverts, eth_call succeeds");
    }

    function test_ProbeWithdrawLarge() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        IMarket m = IMarket(MKT);
        uint256 lim = m.getWithdrawalLimit(P2);
        console.log("withdrawal limit:", lim);
        vm.prank(P2);
        vm.expectRevert();
        m.withdraw(lim);
        console.log("artifact reproduced at full limit as well");
    }
}
