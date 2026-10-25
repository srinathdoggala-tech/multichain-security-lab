// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "forge-std/Test.sol";
import "../src/SignatureVault.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract SignatureAttackTest is Test {
    SignatureVault vault;
    uint256 adminPrivateKey = 0xA11CE;
    address admin;

    function setUp() public {
        admin = vm.addr(adminPrivateKey);
        vault = new SignatureVault(admin);
        vm.deal(address(vault), 100 ether);
    }

    function testSignatureMalleability() public {
        uint256 amount = 1 ether;
        uint256 startBalance = address(this).balance;

        bytes32 messageHash = keccak256(abi.encodePacked(address(this), amount));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vault.claimPrize(amount, signature);

        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 invS = bytes32(n - uint256(s));
        uint8 invV = v == 27 ? 28 : 27;
        bytes memory malleSignature = abi.encodePacked(r, invS, invV);

        vm.expectRevert();
        vault.claimPrize(amount, malleSignature);

        assertEq(address(this).balance, startBalance + 1 ether);
    }
    receive() external payable {}
}
