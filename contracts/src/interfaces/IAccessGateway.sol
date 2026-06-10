// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccessGateway
/// @notice Interface for the time-boxed access gateway protocol
/// @dev Implementations must emit the required events and implement all functions
interface IAccessGateway {
    // =========================================================================
    //                              STRUCTS
    // =========================================================================

    /// @notice Pricing tier configuration
    struct Tier {
        uint256 durationSeconds; // How long this tier lasts
        uint256 priceWei;        // Cost in wei
        bool active;             // Whether this tier can be purchased
        string label;            // Human-readable label e.g. "1 Hour"
    }

    // =========================================================================
    //                              EVENTS
    // =========================================================================

    /// @notice Emitted when a new access session is granted
    /// @param user         The wallet address purchasing access
    /// @param deviceId     Off-chain identifier (MAC address hash, device fingerprint)
    /// @param tierId       The pricing tier selected
    /// @param expiresAt    Block timestamp when access expires
    /// @param amountPaid   ETH paid in wei
    event AccessGranted(
        address indexed user,
        bytes32 indexed deviceId,
        uint256 indexed tierId,
        uint256 expiresAt,
        uint256 amountPaid
    );

    /// @notice Emitted when a session is explicitly revoked by the owner
    event AccessRevoked(address indexed user, bytes32 indexed deviceId);

    /// @notice Emitted when a session is extended
    event AccessExtended(
        address indexed user,
        bytes32 indexed deviceId,
        uint256 newExpiresAt,
        uint256 amountPaid
    );

    /// @notice Emitted when a pricing tier is created or updated
    event TierUpdated(uint256 indexed tierId, uint256 durationSeconds, uint256 priceWei);

    /// @notice Emitted when accumulated ETH is withdrawn
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when the contract is paused/unpaused
    event EmergencyPause(bool paused);

    // =========================================================================
    //                              ERRORS
    // =========================================================================

    error InsufficientPayment(uint256 required, uint256 sent);
    error InvalidTier(uint256 tierId);
    error TierInactive(uint256 tierId);
    error SessionAlreadyActive(address user, bytes32 deviceId, uint256 expiresAt);
    error SessionNotFound(address user, bytes32 deviceId);
    error ContractPaused();
    error WithdrawFailed();
    error ZeroAddress();
    error InvalidDuration();
    error InvalidPrice();
    error ArrayLengthMismatch();

    // =========================================================================
    //                              FUNCTIONS
    // =========================================================================

    /// @notice Purchase access for a device
    /// @param deviceId  Off-chain device identifier (keccak256 of MAC or fingerprint)
    /// @param tierId    Tier to purchase
    function purchaseAccess(bytes32 deviceId, uint256 tierId) external payable;

    /// @notice Extend an existing active session
    /// @param deviceId  The device to extend access for
    /// @param tierId    Tier to extend by
    function extendAccess(bytes32 deviceId, uint256 tierId) external payable;

    /// @notice Check if a device currently has valid access
    /// @param user      Wallet address of the session owner
    /// @param deviceId  Device identifier
    /// @return active   Whether access is currently valid
    /// @return expiresAt Unix timestamp of expiry (0 if not active)
    function checkAccess(address user, bytes32 deviceId)
        external
        view
        returns (bool active, uint256 expiresAt);

    /// @notice Returns remaining seconds of access for a device
    /// @param user      Wallet address
    /// @param deviceId  Device identifier
    /// @return remainingSeconds  Remaining access time (0 if expired or not found)
    function remainingTime(address user, bytes32 deviceId) external view returns (uint256 remainingSeconds);

    /// @notice Get tier details
    /// @param tierId  Tier index
    /// @return tier   The Tier struct
    function getTier(uint256 tierId) external view returns (Tier memory tier);

    /// @notice Get all active tiers
    /// @return tiers  Array of all tiers
    function getAllTiers() external view returns (Tier[] memory tiers);

    /// @notice Revoke access for a device (owner only, emergency use)
    /// @param user      Session owner wallet
    /// @param deviceId  Device identifier
    function revokeAccess(address user, bytes32 deviceId) external;

    /// @notice Withdraw accumulated ETH to treasury
    function withdraw() external;

    /// @notice Toggle emergency pause
    function togglePause() external;
}
