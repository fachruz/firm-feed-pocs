// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IMarket} from "../src/Interfaces.sol";

/// Probe: does the yv-reUSD market's (Yearn-based) escrow pay() path execute
/// on a plain fork? P4 has large withdrawal headroom at baseline.
contract ProbeYvPayTest is Test {
    uint256 constant FORK_BLOCK = 26436361;
    address constant YVMKT = 0x1fD4985cdd57bDb1eD646B10B7952fCD58946916;
    address constant P4 = 0xAAc0aa431c237C2C0B5f041c8e59B3f1a43aC78F;

    function test_ProbeYvWithdrawSmall() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        IMarket m = IMarket(YVMKT);
        console.log("P4 withdrawal limit:", m.getWithdrawalLimit(P4));
        vm.prank(P4);
        m.withdraw(100 ether);
        console.log("yv withdraw 100: OK");
    }
}
