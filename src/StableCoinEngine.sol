// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {PriceLib, AggregatorV3Interface} from "./library/PriceLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyStableCoin} from "./MyStableCoin.sol";

contract StableCoinEngine is ReentrancyGuard {
    using PriceLib for AggregatorV3Interface;

    // errors
    error StableCoinEngine__TransferFailed();
    error StableCoinEngine__MintFailed();
    error StableCoinEngine__NeedsMoreThanZero();
    error StableCoinEngine__TokenNotAllowed(address token);
    error StableCoinEngine__BreaksHealthFactor(uint256 healthFactor);
    error StableCoinEngine__HealthFactorOk();
    error StableCoinEngine__HealthFactorNotImproved();

    // constants
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    // events
    event CollateralDesposit(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeem(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    // modifier
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert StableCoinEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert StableCoinEngine__TokenNotAllowed(token);
        }
        _;
    }

    MyStableCoin private immutable i_msc;

    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposit;
    mapping(address user => uint256 amount) private s_MSCMinted;

    address[] private s_collateralTokens;

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address mscAddress) {
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_msc = MyStableCoin(mscAddress);
    }

    function depositCollateralAndMintMsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountMscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintMsc(amountMscToMint);
    }

    function redeemCollateralForMsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountMscToBurn)
        external
        moreThanZero(amountCollateral)
    {
        _burnMsc(amountMscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public nonReentrant {
        s_collateralDeposit[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDesposit(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert StableCoinEngine__TransferFailed();
        }
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert StableCoinEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / 100;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnMsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert StableCoinEngine__HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintMsc(uint256 amountMscToMint) public {
        s_MSCMinted[msg.sender] += amountMscToMint;

        bool minted = i_msc.mint(msg.sender, amountMscToMint);
        if (!minted) {
            revert StableCoinEngine__MintFailed();
        }
    }

    function burnMsc(uint256 amount) external moreThanZero(amount) {
        _burnMsc(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposit[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stableCheckLatestPrice();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert StableCoinEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposit[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeem(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert StableCoinEngine__TransferFailed();
        }
    }

    function _burnMsc(uint256 amountMscToBurn, address onBehalfOf, address mscFrom) private {
        s_MSCMinted[onBehalfOf] -= amountMscToBurn;

        bool success = i_msc.transferFrom(mscFrom, address(this), amountMscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert StableCoinEngine__TransferFailed();
        }
        i_msc.burn(amountMscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalMscMinted, uint256 collateralValueInUsd)
    {
        totalMscMinted = s_MSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalMscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalMscMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stableCheckLatestPrice();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalMscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalMscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalMscMinted;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposit[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getMsc() external view returns (address) {
        return address(i_msc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
