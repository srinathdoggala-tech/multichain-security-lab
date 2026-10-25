// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract SignatureReplayVault {
    using ECDSA for bytes32;

    error InvalidSignature();
    error SignatureAlreadyUsed();
    error TransferFailed();

    address public immutable owner;
    mapping(bytes32 => bool) public executedHashes;

    constructor(address _owner) payable {
        owner = _owner;
    }

    function withdrawWithSignature(uint256 amount, bytes calldata signature) external {
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, amount));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        address signer = ethSignedMessageHash.recover(signature);

        if (signer != owner) revert InvalidSignature();
        if (executedHashes[messageHash]) revert SignatureAlreadyUsed();

        executedHashes[messageHash] = true;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    receive() external payable {}
}
