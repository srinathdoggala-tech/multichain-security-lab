// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract BridgeProofVault {
    bytes32 public root;
    mapping(bytes32 => bool) public processedWithdrwals;

    error ProofInvalid();
    error AlreadyProcessed();
    error TransferFailed();

    constructor(bytes32 _root) payable {
        root = _root;
    }

    function withdrawBridgeFunds(
        address to,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        bytes32 leaf = keccak256(abi.encodePacked(to, amount));
        
        if (!MerkleProof.verify(proof, root, leaf)) revert ProofInvalid();
        if (processedWithdrwals[leaf]) revert AlreadyProcessed();

        processedWithdrwals[leaf] = true;

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    receive() external payable {}
}
