//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract CrossChainMessageVault {
    using ECDSA for bytes32;

    address public immutable bridgeValidator;
    mapping(bytes32 => bool) public executedMessages;

    error InvalidatorSignature();
    error MessageAlreadyExecuted();
    error EtherTransferFailed();

    constructor(address _validator) payable {
        bridgeValidator = _validator;
    }

    function executeCrossChainWithdrawal(address to, uint256 amount, uint256 nonce, bytes calldata validatorSignature)
        external
    {
        bytes32 messageHash = keccak256(abi.encodePacked(to, amount, nonce));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        address signer = ethSignedHash.recover(validatorSignature);

        if (signer != bridgeValidator) revert InvalidatorSignature();
        if (executedMessages[messageHash]) revert MessageAlreadyExecuted();

        executedMessages[messageHash] = true;

        (bool success,) = to.call{value: amount}("");
        if (!success) revert EtherTransferFailed();
    }
    receive() external payable {}
}
