// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {PriceLib, AggregatorV3Interface} from "./library/PriceLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyStableCoin} from "./MyStableCoin.sol";

contract StableCoinEngine is ReentrancyGuard {
    // errors
    error StableCoinEngine__TransferFailed();
    error StableCoinEngine__MintFailed();

    using PriceLib for AggregatorV3Interface;

    MyStableCoin private immutable i_msc;

    event CollateralDesposit(address indexed user, address indexed token, uint256 indexed amount);

    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address collateralToken => uint256 amount))
        private s_collateralDeposit;
    mapping(address user => uint256 amount) private s_MSCMinted;

    address[] private s_coollateralTokens;

    constructor(
        address[] memory tokenAddress,
        address[] memory priceFeedAddress,
        address mscAddress
    ) {
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_coollateralTokens.push(tokenAddress[i]);
        }
        i_msc = MyStableCoin(mscAddress);
    }

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountMscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintMsc(amountMscToMint);
    }

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public nonReentrant {
        s_collateralDeposit[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDesposit(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success) {
            revert StableCoinEngine__TransferFailed();
        }
        
    }

    function mintMsc(uint256 amountMscToMint) public {
        s_MSCMinted[msg.sender] += amountMscToMint;

        bool minted = i_msc.mint(msg.sender, amountMscToMint);
        if(!minted){
            revert StableCoinEngine__MintFailed();
        }
        
    }
}
