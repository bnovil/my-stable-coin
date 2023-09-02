// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MyStableCoin is ERC20Burnable, Ownable {
    error MyStableCoin__AmountMustBeMoreThanZero();
    error MyStableCoin__BurnAmountExceedsBalance();
    error MyStableCoin__NotZeroAddress();

    constructor(address initialOwner) ERC20("MyStableCoin", "MSC") Ownable(initialOwner) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert MyStableCoin__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert MyStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert MyStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert MyStableCoin__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
