// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Vault {
    address private _owner;
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    uint256 private _totalGems;

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    constructor() {
        _owner = msg.sender;
    }

    function changeOwner(address newOwner) external onlyOwner {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    function depositGems(uint256 amount) external {
        _totalGems += amount;
    }

    function withdrawAll() external onlyOwner {
        _totalGems = 0;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}
