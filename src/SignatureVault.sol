// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract SignatureVault {
    using ECDSA for bytes32;
    address public admin;
    mapping(bytes32 => bool) public usedSignatures;

    constructor(address _admin) {
        admin = _admin;
    }

    function claimPrize(uint256 amount, bytes calldata signature) external {
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, amount));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        address signer = ethSignedMessageHash.recover(signature);
        require(signer == admin, "Invalid signature");

        bytes32 sigHash = keccak256(signature);
        require(!usedSignatures[sigHash], "Signature already used");

        usedSignatures[sigHash] = true;
        payable(msg.sender).transfer(amount);
    }
    receive() external payable {}
}
