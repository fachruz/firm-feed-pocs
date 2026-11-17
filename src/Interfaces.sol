// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Interfaces matching the DEPLOYED FiRM contracts (verified sources in
// ../../firm-feeds-src). Used only against a local mainnet fork.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ICurvePoolNG {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_p(uint256 i) external view returns (uint256);
    function price_oracle(uint256 i) external view returns (uint256);
    function last_price(uint256 i) external view returns (uint256);
    function ema_price(uint256 i) external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
    function get_virtual_price() external view returns (uint256);
    function ma_exp_time() external view returns (uint256);
    function fee() external view returns (uint256);
    function A() external view returns (uint256);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IWindDownFeed {
    function startWindDown() external;
    function stopWindDown() external;
    function canStartWindDown() external view returns (bool);
    function windDownStartPrice() external view returns (uint256);
    function windDownStartedAt() external view returns (uint256);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function RWG() external view returns (address);
}

interface IOracle {
    function getPrice(address token, uint256 collateralFactorBps) external returns (uint256);
    function viewPrice(address token, uint256 collateralFactorBps) external view returns (uint256);
    function dailyLows(address token, uint256 day) external view returns (uint256);
    function feeds(address token) external view returns (address feed, uint8 tokenDecimals);
}

interface IBorrowController {
    function borrowAllowed(address msgSender, address borrower, uint256 amount) external returns (bool);
    function isPriceStale(address market) external view returns (bool);
    function stalenessThreshold(address market) external view returns (uint256);
    function dailyLimits(address market) external view returns (uint256);
    function allow(address allowedContract) external;
    function operator() external view returns (address);
}

interface IDBR {
    function balanceOf(address user) external view returns (uint256);
    function deficitOf(address user) external view returns (uint256);
    function debts(address user) external view returns (uint256);
}

interface IEscrow {
    function balance() external view returns (uint256);
}

interface IMarket {
    function deposit(uint256 amount) external;
    function borrow(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function liquidate(address user, uint256 repaidDebt) external;
    function repay(address user, uint256 amount) external;
    function debts(address user) external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function collateralFactorBps() external view returns (uint256);
    function liquidationIncentiveBps() external view returns (uint256);
    function liquidationFeeBps() external view returns (uint256);
    function liquidationFactorBps() external view returns (uint256);
    function getCreditLimit(address user) external view returns (uint256);
    function getWithdrawalLimit(address user) external view returns (uint256);
    function getCollateralValue(address user) external view returns (uint256);
    function predictEscrow(address user) external view returns (address);
    function oracle() external view returns (address);
    function borrowController() external view returns (address);
    function dbr() external view returns (address);
    function collateral() external view returns (address);
}

interface IOneDolaFeedSwitch {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function isFixedPriceActive() external view returns (bool);
    function toggleFeedSwitch() external;
    function borrowThreshold() external view returns (int256);
    function timelockPeriod() external view returns (uint256);
}
