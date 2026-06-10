// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessGateway} from "../../src/AccessGateway.sol";
import {SessionRegistry} from "../../src/SessionRegistry.sol";
import {IAccessGateway} from "../../src/interfaces/IAccessGateway.sol";

/// @title FuzzAccessGateway
/// @notice Property-based fuzz tests. Foundry will run these with thousands of
///         random inputs to find edge cases that unit tests miss.
contract FuzzAccessGateway is Test {

    AccessGateway public gateway;
    SessionRegistry public registry;

    address public owner    = makeAddr("owner");
    address payable public treasury = payable(makeAddr("treasury"));

    function setUp() public {
        vm.startPrank(owner);
        registry = new SessionRegistry(owner);
        gateway  = new AccessGateway(address(registry), treasury, owner);
        registry.setGateway(address(gateway));
        vm.stopPrank();
    }

    // =========================================================================
    //                      PROPERTY: PAYMENT INTEGRITY
    // =========================================================================

    /// @notice For any valid tier, overpaying should refund the excess exactly.
    ///         The contract should never take more than the tier price.
    function testFuzz_Overpayment_AlwaysRefunded(uint256 overpayAmount) public {
        overpayAmount = bound(overpayAmount, 0, 100 ether);

        IAccessGateway.Tier memory tier = gateway.getTier(0);
        uint256 payment = tier.priceWei + overpayAmount;

        address user = makeAddr("fuzzy_user");
        vm.deal(user, payment + 1 ether); // extra buffer for gas

        uint256 balBefore = user.balance;
        bytes32 deviceId = keccak256("fuzz_device");

        vm.prank(user);
        gateway.purchaseAccess{value: payment}(deviceId, 0);

        // User should have lost exactly the tier price (not the overpay)
        assertApproxEqAbs(
            user.balance,
            balBefore - tier.priceWei,
            1e12, // gas tolerance
            "Overpay refund incorrect"
        );
    }

    /// @notice For any amount below the tier price, the purchase must revert.
    function testFuzz_UnderpaymentAlwaysReverts(uint256 underpayAmount) public {
        IAccessGateway.Tier memory tier = gateway.getTier(0);
        // Bound to [0, price - 1]
        underpayAmount = bound(underpayAmount, 0, tier.priceWei - 1);

        address user = makeAddr("underpay_user");
        vm.deal(user, tier.priceWei);

        vm.prank(user);
        vm.expectRevert();
        gateway.purchaseAccess{value: underpayAmount}(keccak256("dev"), 0);
    }

    // =========================================================================
    //                    PROPERTY: TIMESTAMP CORRECTNESS
    // =========================================================================

    /// @notice Expiry must always be exactly block.timestamp + tier.durationSeconds
    ///         regardless of when the purchase happens.
    function testFuzz_ExpiryIsExact(uint256 warpSeconds) public {
        // Warp within a reasonable window (up to 10 years)
        warpSeconds = bound(warpSeconds, 0, 365 days * 10);
        vm.warp(block.timestamp + warpSeconds);

        IAccessGateway.Tier memory tier = gateway.getTier(2); // 24h tier
        uint256 expectedExpiry = block.timestamp + tier.durationSeconds;

        address user = makeAddr("warp_user");
        vm.deal(user, 10 ether);
        bytes32 deviceId = keccak256("warp_device");

        vm.prank(user);
        gateway.purchaseAccess{value: tier.priceWei}(deviceId, 2);

        (, uint256 actualExpiry) = gateway.checkAccess(user, deviceId);
        assertEq(actualExpiry, expectedExpiry, "Expiry must equal timestamp + duration");
    }

    /// @notice remainingTime must never underflow (should return 0, not wrap around)
    function testFuzz_RemainingTime_NeverUnderflows(uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, 0, 365 days);

        address user = makeAddr("time_user");
        vm.deal(user, 10 ether);
        bytes32 deviceId = keccak256("time_device");

        vm.prank(user);
        gateway.purchaseAccess{value: 0.001 ether}(deviceId, 0);

        vm.warp(block.timestamp + warpSeconds);

        uint256 remaining = gateway.remainingTime(user, deviceId);
        // Must never revert or underflow
        assertGe(remaining, 0, "Remaining time must never underflow");
    }

    // =========================================================================
    //               PROPERTY: ACCESS STATE CONSISTENCY
    // =========================================================================

    /// @notice If checkAccess returns active=true, remainingTime must be > 0.
    ///         If active=false, remainingTime must be 0.
    function testFuzz_AccessAndRemainingTime_Consistent(uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, 0, 365 days);

        address user = makeAddr("consistent_user");
        vm.deal(user, 10 ether);
        bytes32 deviceId = keccak256("consistent_device");

        vm.prank(user);
        gateway.purchaseAccess{value: 0.001 ether}(deviceId, 0);

        vm.warp(block.timestamp + warpSeconds);

        (bool active,) = gateway.checkAccess(user, deviceId);
        uint256 remaining = gateway.remainingTime(user, deviceId);

        if (active) {
            assertGt(remaining, 0, "Active session must have remaining time > 0");
        } else {
            assertEq(remaining, 0, "Inactive session must have remaining time == 0");
        }
    }

    // =========================================================================
    //                PROPERTY: EXTENSION NEVER SHORTENS SESSION
    // =========================================================================

    /// @notice Extending a session must always produce a new expiry strictly
    ///         greater than the old expiry.
    function testFuzz_Extension_NeverShortensSession(uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, 0, 30 minutes); // Keep within 1hr session

        address user = makeAddr("ext_user");
        vm.deal(user, 10 ether);
        bytes32 deviceId = keccak256("ext_device");

        vm.prank(user);
        gateway.purchaseAccess{value: 0.001 ether}(deviceId, 0);

        (, uint256 expiryBefore) = gateway.checkAccess(user, deviceId);

        vm.warp(block.timestamp + warpSeconds);

        vm.prank(user);
        gateway.extendAccess{value: 0.001 ether}(deviceId, 0);

        (, uint256 expiryAfter) = gateway.checkAccess(user, deviceId);
        assertGt(expiryAfter, expiryBefore, "Extending must not shorten the session");
    }

    // =========================================================================
    //               PROPERTY: REVENUE ACCOUNTING
    // =========================================================================

    /// @notice totalRevenue must equal the contract's ETH balance at all times
    ///         (since we haven't withdrawn yet).
    function testFuzz_RevenueMatchesBalance(uint8 purchaseCount) public {
        purchaseCount = uint8(bound(uint256(purchaseCount), 1, 20));

        IAccessGateway.Tier memory tier = gateway.getTier(0);
        uint256 expectedRevenue;

        for (uint256 i = 0; i < purchaseCount; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));
            vm.deal(user, 10 ether);
            bytes32 device = keccak256(abi.encodePacked("device", i));

            vm.prank(user);
            gateway.purchaseAccess{value: tier.priceWei}(device, 0);
            expectedRevenue += tier.priceWei;
        }

        assertEq(gateway.totalRevenue(), expectedRevenue);
        assertEq(address(gateway).balance, expectedRevenue);
    }

    // =========================================================================
    //                PROPERTY: TIER VALIDATION BOUNDS
    // =========================================================================

    /// @notice Any tierId >= tierCount must always revert with InvalidTier.
    function testFuzz_InvalidTierId_AlwaysReverts(uint256 badTierId) public {
        uint256 count = gateway.tierCount();
        badTierId = bound(badTierId, count, type(uint256).max);

        address user = makeAddr("bad_tier_user");
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessGateway.InvalidTier.selector, badTierId)
        );
        gateway.purchaseAccess{value: 1 ether}(keccak256("d"), badTierId);
    }
}
