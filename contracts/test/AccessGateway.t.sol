// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessGateway} from "../src/AccessGateway.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {IAccessGateway} from "../src/interfaces/IAccessGateway.sol";

/// @title AccessGatewayTest
/// @notice Comprehensive unit test suite for the AccessGateway protocol
contract AccessGatewayTest is Test {
    // =========================================================================
    //                              SETUP
    // =========================================================================

    AccessGateway public gateway;
    SessionRegistry public registry;

    address public owner = makeAddr("owner");
    address payable public treasury = payable(makeAddr("treasury"));
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    bytes32 public constant DEVICE_ALICE = keccak256("alice_device_mac");
    bytes32 public constant DEVICE_BOB   = keccak256("bob_device_mac");
    bytes32 public constant DEVICE_EVIL  = keccak256("evil_device");

    // Default tier 0: 1 hour @ 0.001 ETH
    uint256 public constant TIER_1H    = 0;
    uint256 public constant TIER_6H    = 1;
    uint256 public constant TIER_24H   = 2;
    uint256 public constant TIER_7D    = 3;

    uint256 public constant PRICE_1H   = 0.001 ether;
    uint256 public constant PRICE_6H   = 0.005 ether;
    uint256 public constant PRICE_24H  = 0.015 ether;
    uint256 public constant PRICE_7D   = 0.08 ether;

    event AccessGranted(
        address indexed user,
        bytes32 indexed deviceId,
        uint256 indexed tierId,
        uint256 expiresAt,
        uint256 amountPaid
    );
    event AccessRevoked(address indexed user, bytes32 indexed deviceId);
    event AccessExtended(
        address indexed user,
        bytes32 indexed deviceId,
        uint256 newExpiresAt,
        uint256 amountPaid
    );

    function setUp() public {
        vm.startPrank(owner);
        registry = new SessionRegistry(owner);
        gateway  = new AccessGateway(address(registry), treasury, owner);
        registry.setGateway(address(gateway));
        vm.stopPrank();

        // Fund test users
        vm.deal(alice,    100 ether);
        vm.deal(bob,      100 ether);
        vm.deal(attacker, 100 ether);
    }

    // =========================================================================
    //                         DEPLOYMENT / CONSTRUCTOR
    // =========================================================================

    function test_Constructor_SetsState() public view {
        assertEq(address(gateway.registry()), address(registry));
        assertEq(gateway.treasury(), treasury);
        assertEq(gateway.owner(), owner);
        assertEq(gateway.tierCount(), 4);
        assertFalse(gateway.paused());
    }

    function test_Constructor_RejectsZeroRegistry() public {
        vm.expectRevert(IAccessGateway.ZeroAddress.selector);
        new AccessGateway(address(0), treasury, owner);
    }

    function test_Constructor_RejectsZeroTreasury() public {
        vm.expectRevert(IAccessGateway.ZeroAddress.selector);
        new AccessGateway(address(registry), payable(address(0)), owner);
    }

    function test_Constructor_RejectsZeroOwner() public {
        vm.expectRevert(IAccessGateway.ZeroAddress.selector);
        new AccessGateway(address(registry), treasury, address(0));
    }

    function test_DefaultTiers_AreCorrect() public view {
        IAccessGateway.Tier memory t0 = gateway.getTier(0);
        assertEq(t0.durationSeconds, 1 hours);
        assertEq(t0.priceWei, PRICE_1H);
        assertTrue(t0.active);
        assertEq(t0.label, "1 Hour");

        IAccessGateway.Tier memory t3 = gateway.getTier(3);
        assertEq(t3.durationSeconds, 7 days);
        assertEq(t3.priceWei, PRICE_7D);
    }

    // =========================================================================
    //                         PURCHASE ACCESS — HAPPY PATH
    // =========================================================================

    function test_PurchaseAccess_1Hour() public {
        uint256 expBefore = block.timestamp + 1 hours;

        vm.expectEmit(true, true, true, true);
        emit AccessGranted(alice, DEVICE_ALICE, TIER_1H, expBefore, PRICE_1H);

        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        (bool active, uint256 expiresAt) = gateway.checkAccess(alice, DEVICE_ALICE);
        assertTrue(active);
        assertEq(expiresAt, expBefore);
        assertEq(gateway.remainingTime(alice, DEVICE_ALICE), 1 hours);
        assertEq(gateway.totalRevenue(), PRICE_1H);
    }

    function test_PurchaseAccess_Overpayment_IsRefunded() public {
        uint256 aliceBalanceBefore = alice.balance;
        uint256 overpay = PRICE_1H + 0.5 ether;

        vm.prank(alice);
        gateway.purchaseAccess{value: overpay}(DEVICE_ALICE, TIER_1H);

        // Alice should only lose the tier price, not the overpaid amount
        assertApproxEqAbs(alice.balance, aliceBalanceBefore - PRICE_1H, 1e12); // tolerance for gas
    }

    function test_PurchaseAccess_MultipleUsers() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        vm.prank(bob);
        gateway.purchaseAccess{value: PRICE_24H}(DEVICE_BOB, TIER_24H);

        (bool activeAlice,) = gateway.checkAccess(alice, DEVICE_ALICE);
        (bool activeBob,)   = gateway.checkAccess(bob,   DEVICE_BOB);

        assertTrue(activeAlice);
        assertTrue(activeBob);
        assertEq(gateway.totalRevenue(), PRICE_1H + PRICE_24H);
    }

    function test_PurchaseAccess_AllTiers() public {
        bytes32[4] memory devices = [
            keccak256("dev0"), keccak256("dev1"),
            keccak256("dev2"), keccak256("dev3")
        ];
        uint256[4] memory prices = [PRICE_1H, PRICE_6H, PRICE_24H, PRICE_7D];

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            gateway.purchaseAccess{value: prices[i]}(devices[i], i);
            (bool active,) = gateway.checkAccess(alice, devices[i]);
            assertTrue(active, "Session should be active");
        }
    }

    // =========================================================================
    //                         PURCHASE ACCESS — FAILURE CASES
    // =========================================================================

    function test_Revert_InsufficientPayment() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessGateway.InsufficientPayment.selector, PRICE_1H, 1 wei)
        );
        gateway.purchaseAccess{value: 1 wei}(DEVICE_ALICE, TIER_1H);
    }

    function test_Revert_InvalidTier() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessGateway.InvalidTier.selector, 999));
        gateway.purchaseAccess{value: 1 ether}(DEVICE_ALICE, 999);
    }

    function test_Revert_SessionAlreadyActive() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        vm.prank(alice);
        vm.expectRevert();  // SessionAlreadyActive
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);
    }

    function test_Revert_TierInactive() public {
        vm.prank(owner);
        gateway.deactivateTier(TIER_1H);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessGateway.TierInactive.selector, TIER_1H));
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);
    }

    function test_Revert_WhenPaused() public {
        vm.prank(owner);
        gateway.togglePause();

        vm.prank(alice);
        vm.expectRevert();
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);
    }

    function test_PurchaseAfterExpiry_Succeeds() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        (bool active,) = gateway.checkAccess(alice, DEVICE_ALICE);
        assertFalse(active, "Session should be expired");

        // Should be able to purchase again
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);
        (active,) = gateway.checkAccess(alice, DEVICE_ALICE);
        assertTrue(active);
    }

    // =========================================================================
    //                              EXTEND ACCESS
    // =========================================================================

    function test_ExtendAccess_AddsToExpiry() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        (, uint256 expiry1) = gateway.checkAccess(alice, DEVICE_ALICE);

        vm.prank(alice);
        gateway.extendAccess{value: PRICE_6H}(DEVICE_ALICE, TIER_6H);

        (, uint256 expiry2) = gateway.checkAccess(alice, DEVICE_ALICE);
        assertEq(expiry2, expiry1 + 6 hours);
    }

    function test_ExtendAccess_FromCurrentTimestamp_IfExpired() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        // Expire the session
        vm.warp(block.timestamp + 2 hours);

        uint256 extendAt = block.timestamp;
        vm.prank(alice);
        gateway.extendAccess{value: PRICE_6H}(DEVICE_ALICE, TIER_6H);

        (, uint256 expiry) = gateway.checkAccess(alice, DEVICE_ALICE);
        assertEq(expiry, extendAt + 6 hours);
    }

    function test_Revert_ExtendAccess_NoSession() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessGateway.SessionNotFound.selector, alice, DEVICE_ALICE)
        );
        gateway.extendAccess{value: PRICE_6H}(DEVICE_ALICE, TIER_6H);
    }

    // =========================================================================
    //                              ACCESS REVOCATION
    // =========================================================================

    function test_RevokeAccess_Owner() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        vm.expectEmit(true, true, false, false);
        emit AccessRevoked(alice, DEVICE_ALICE);

        vm.prank(owner);
        gateway.revokeAccess(alice, DEVICE_ALICE);

        (bool active,) = gateway.checkAccess(alice, DEVICE_ALICE);
        assertFalse(active, "Session should be revoked");
    }

    function test_Revert_RevokeAccess_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.revokeAccess(alice, DEVICE_ALICE);
    }

    // =========================================================================
    //                              TIER MANAGEMENT
    // =========================================================================

    function test_AddTier() public {
        uint256 countBefore = gateway.tierCount();

        vm.prank(owner);
        gateway.addTier(30 minutes, 0.0005 ether, "30 Minutes");

        assertEq(gateway.tierCount(), countBefore + 1);
        IAccessGateway.Tier memory t = gateway.getTier(countBefore);
        assertEq(t.durationSeconds, 30 minutes);
        assertEq(t.priceWei, 0.0005 ether);
        assertTrue(t.active);
        assertEq(t.label, "30 Minutes");
    }

    function test_UpdateTier() public {
        vm.prank(owner);
        gateway.updateTier(TIER_1H, 2 hours, 0.002 ether, true, "2 Hours");

        IAccessGateway.Tier memory t = gateway.getTier(TIER_1H);
        assertEq(t.durationSeconds, 2 hours);
        assertEq(t.priceWei, 0.002 ether);
        assertEq(t.label, "2 Hours");
    }

    function test_Revert_AddTier_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.addTier(1 hours, 0.001 ether, "Hacked");
    }

    function test_Revert_AddTier_ZeroPrice() public {
        vm.prank(owner);
        vm.expectRevert(IAccessGateway.InvalidPrice.selector);
        gateway.addTier(1 hours, 0, "Free");
    }

    function test_Revert_AddTier_DurationTooShort() public {
        vm.prank(owner);
        vm.expectRevert(IAccessGateway.InvalidDuration.selector);
        gateway.addTier(30 seconds, 0.001 ether, "Too Short");
    }

    // =========================================================================
    //                              WITHDRAWAL
    // =========================================================================

    function test_Withdraw_TransfersToTreasury() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_24H}(DEVICE_ALICE, TIER_24H);

        vm.prank(bob);
        gateway.purchaseAccess{value: PRICE_7D}(DEVICE_BOB, TIER_7D);

        uint256 treasuryBefore = treasury.balance;
        uint256 expected = PRICE_24H + PRICE_7D;

        vm.prank(owner);
        gateway.withdraw();

        assertEq(treasury.balance, treasuryBefore + expected);
        assertEq(address(gateway).balance, 0);
    }

    function test_Revert_Withdraw_NotOwner() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        vm.prank(attacker);
        vm.expectRevert();
        gateway.withdraw();
    }

    function test_Revert_Withdraw_EmptyBalance() public {
        vm.prank(owner);
        vm.expectRevert(IAccessGateway.WithdrawFailed.selector);
        gateway.withdraw();
    }

    // =========================================================================
    //                              REENTRANCY GUARD
    // =========================================================================

    function test_ReentrancyGuard_OnPurchase() public {
        ReentrantAttacker re = new ReentrantAttacker(payable(address(gateway)));
        vm.deal(address(re), 10 ether);

        // The attack should fail without draining funds
        vm.expectRevert();
        re.attack{value: PRICE_1H}();
    }

    // =========================================================================
    //                              RECEIVE / FALLBACK
    // =========================================================================

    function test_Revert_DirectEthTransfer() public {
        (bool ok,) = address(gateway).call{value: 1 ether}("");
        assertFalse(ok, "Direct ETH transfer should revert");
    }

    // =========================================================================
    //                              REMAINING TIME
    // =========================================================================

    function test_RemainingTime_DecreasesWithWarp() public {
        vm.prank(alice);
        gateway.purchaseAccess{value: PRICE_1H}(DEVICE_ALICE, TIER_1H);

        assertEq(gateway.remainingTime(alice, DEVICE_ALICE), 1 hours);

        vm.warp(block.timestamp + 30 minutes);
        assertEq(gateway.remainingTime(alice, DEVICE_ALICE), 30 minutes);

        vm.warp(block.timestamp + 31 minutes);
        assertEq(gateway.remainingTime(alice, DEVICE_ALICE), 0);
    }

    // =========================================================================
    //                              GET ALL TIERS
    // =========================================================================

    function test_GetAllTiers() public view {
        IAccessGateway.Tier[] memory tiers = gateway.getAllTiers();
        assertEq(tiers.length, 4);
        assertEq(tiers[0].priceWei, PRICE_1H);
        assertEq(tiers[3].durationSeconds, 7 days);
    }

    // =========================================================================
    //                         EMERGENCY PAUSE
    // =========================================================================

    function test_Pause_And_Unpause() public {
        assertFalse(gateway.paused());

        vm.prank(owner);
        gateway.togglePause();
        assertTrue(gateway.paused());

        vm.prank(owner);
        gateway.togglePause();
        assertFalse(gateway.paused());
    }

    // =========================================================================
    //                         SESSION REGISTRY ISOLATION
    // =========================================================================

    function test_RegistryWrite_OnlyGateway() public {
        // Direct call to registry from non-gateway should revert
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(SessionRegistry.NotGateway.selector, attacker)
        );
        registry.upsertSession(alice, DEVICE_ALICE, block.timestamp + 1 hours, 0, PRICE_1H);
    }

    function test_Registry_OwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        // Pending until accepted
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), newOwner);

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);
    }
}

// =========================================================================
//                    HELPER: REENTRANCY ATTACKER CONTRACT
// =========================================================================

contract ReentrantAttacker {
    AccessGateway private target;
    bytes32 private constant DEVICE = keccak256("evil");

    constructor(address payable _target) {
        target = AccessGateway(_target);
    }

    function attack() external payable {
        target.purchaseAccess{value: 0.001 ether}(DEVICE, 0);
    }

    receive() external payable {
        // Attempt re-entry on receive
        if (address(target).balance >= 0.001 ether) {
            target.purchaseAccess{value: 0.001 ether}(DEVICE, 0);
        }
    }
}
