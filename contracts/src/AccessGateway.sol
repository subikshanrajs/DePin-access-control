// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessGateway} from "./interfaces/IAccessGateway.sol";
import {SessionRegistry} from "./SessionRegistry.sol";

/// @title AccessGateway
/// @notice Production-grade time-boxed network access protocol for Arbitrum.
///         Users pay ETH to unlock a device/network for a fixed time window.
///         An off-chain IoT worker listens to emitted events and configures
///         physical hardware (routers, RADIUS servers, etc.) accordingly.
///
/// @dev Security properties:
///      - ReentrancyGuard: prevents re-entrancy on all payable functions
///      - Pausable: owner can halt all purchases in an emergency
///      - Ownable2Step: two-step ownership transfer prevents accidental owner loss
///      - Pull-over-push: ETH is accumulated; owner explicitly calls withdraw()
///      - Checks-Effects-Interactions: state is written to registry BEFORE emitting events
///      - No floating-point: all time/price calculations use integer arithmetic
///
/// @custom:security-contact security@yourprotocol.xyz
contract AccessGateway is IAccessGateway, Ownable, Ownable2Step, ReentrancyGuard, Pausable {
    // =========================================================================
    //                              CONSTANTS
    // =========================================================================

    /// @dev Minimum session duration: 1 minute. Prevents dust attacks.
    uint256 public constant MIN_DURATION = 60 seconds;

    /// @dev Maximum session duration: 30 days. Prevents locking up tokens too long.
    uint256 public constant MAX_DURATION = 30 days;

    /// @dev Maximum number of tiers. Prevents unbounded loops.
    uint256 public constant MAX_TIERS = 32;

    // =========================================================================
    //                              STORAGE
    // =========================================================================

    /// @notice The session data store (separate contract for upgradeability)
    SessionRegistry public immutable registry;

    /// @notice Address that receives withdrawn ETH (treasury / multisig)
    address payable public treasury;

    /// @notice All pricing tiers. Index = tierId.
    Tier[] private _tiers;

    /// @notice Accumulated protocol revenue (wei). Tracks what can be withdrawn.
    uint256 public totalRevenue;

    // =========================================================================
    //                              CONSTRUCTOR
    // =========================================================================

    /// @param _registry   Deployed SessionRegistry address
    /// @param _treasury   Address to receive withdrawn ETH
    /// @param _owner      Protocol owner / multisig
    constructor(
        address _registry,
        address payable _treasury,
        address _owner
    ) Ownable(_owner) {
        if (_registry == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        registry = SessionRegistry(_registry);
        treasury = _treasury;
        

        // Seed default tiers on deployment
        // These can be updated or disabled by the owner at any time
        _addTier(1 hours,  0.001 ether, "1 Hour");
        _addTier(6 hours,  0.005 ether, "6 Hours");
        _addTier(24 hours, 0.015 ether, "24 Hours");
        _addTier(7 days,   0.08 ether,  "7 Days");
    }

    // Resolve multiple-inheritance overrides between Ownable and Ownable2Step
    function transferOwnership(address newOwner)
        public
        virtual
        override(Ownable, Ownable2Step)
        onlyOwner
    {
        super.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner)
        internal
        virtual
        override(Ownable, Ownable2Step)
    {
        super._transferOwnership(newOwner);
    }

    // =========================================================================
    //                              CORE USER FUNCTIONS
    // =========================================================================

    /// @notice Purchase a new access session for a device.
    ///         The user sends ETH; if access is already active, the call reverts.
    ///         Use extendAccess() to top-up a live session.
    ///
    /// @param deviceId  Off-chain device identifier. Typically keccak256(MAC_address).
    ///                  The IoT worker uses this to locate the physical device.
    /// @param tierId    Index into the _tiers array
    function purchaseAccess(bytes32 deviceId, uint256 tierId)
        external
        payable
        override
        nonReentrant
        whenNotPaused
    {
        Tier memory tier = _validateTier(tierId);
        _validatePayment(tier.priceWei);

        // Prevent double-purchase: revert if a valid session already exists.
        // Users should call extendAccess() while a session is still active.
        (, uint256 currentExpiry) = _checkAccess(msg.sender, deviceId);
        if (currentExpiry > block.timestamp) {
            revert SessionAlreadyActive(msg.sender, deviceId, currentExpiry);
        }

        uint256 expiresAt = block.timestamp + tier.durationSeconds;

        // CEI: Write state BEFORE emitting events
        totalRevenue += msg.value;
        registry.upsertSession(msg.sender, deviceId, expiresAt, tierId, msg.value);

        emit AccessGranted(msg.sender, deviceId, tierId, expiresAt, msg.value);

        // Refund any overpayment (handles "send 0.002 ETH for 0.001 ETH tier" gracefully)
        uint256 excess = msg.value - tier.priceWei;
        if (excess > 0) {
            (bool ok,) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert WithdrawFailed();
        }
    }

    /// @notice Extend an existing (or just-expired) session.
    ///         Adds the tier's duration on top of the current expiry if still active,
    ///         or from block.timestamp if already expired.
    ///
    /// @param deviceId  Device to extend
    /// @param tierId    Tier to add
    function extendAccess(bytes32 deviceId, uint256 tierId)
        external
        payable
        override
        nonReentrant
        whenNotPaused
    {
        Tier memory tier = _validateTier(tierId);
        _validatePayment(tier.priceWei);

        // Session must exist to extend (user must have purchased before)
        (, uint256 currentExpiry) = _checkAccess(msg.sender, deviceId);
        if (currentExpiry == 0) revert SessionNotFound(msg.sender, deviceId);

        uint256 base = currentExpiry > block.timestamp ? currentExpiry : block.timestamp;
        uint256 newExpiry = base + tier.durationSeconds;

        totalRevenue += msg.value;
        registry.extendSession(msg.sender, deviceId, tier.durationSeconds, tierId, msg.value);

        emit AccessExtended(msg.sender, deviceId, newExpiry, msg.value);

        uint256 excess = msg.value - tier.priceWei;
        if (excess > 0) {
            (bool ok,) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert WithdrawFailed();
        }
    }

    // =========================================================================
    //                              VIEW FUNCTIONS
    // =========================================================================

    /// @inheritdoc IAccessGateway
    function checkAccess(address user, bytes32 deviceId)
        external
        view
        override
        returns (bool active, uint256 expiresAt)
    {
        return _checkAccess(user, deviceId);
    }

    /// @inheritdoc IAccessGateway
    function remainingTime(address user, bytes32 deviceId)
        external
        view
        override
        returns (uint256)
    {
        return registry.remainingSeconds(user, deviceId);
    }

    /// @inheritdoc IAccessGateway
    function getTier(uint256 tierId)
        external
        view
        override
        returns (Tier memory)
    {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        return _tiers[tierId];
    }

    /// @inheritdoc IAccessGateway
    function getAllTiers()
        external
        view
        override
        returns (Tier[] memory)
    {
        return _tiers;
    }

    /// @notice How many tiers exist
    function tierCount() external view returns (uint256) {
        return _tiers.length;
    }

    // =========================================================================
    //                              OWNER ADMIN FUNCTIONS
    // =========================================================================

    /// @notice Add a new pricing tier
    /// @param durationSeconds  Session length in seconds (must be between MIN and MAX)
    /// @param priceWei         Cost in wei
    /// @param label            Human-readable label (stored in event / frontend)
    function addTier(uint256 durationSeconds, uint256 priceWei, string calldata label)
        external
        onlyOwner
    {
        if (_tiers.length >= MAX_TIERS) revert ArrayLengthMismatch();
        _addTier(durationSeconds, priceWei, label);
    }

    /// @notice Update an existing tier
    function updateTier(
        uint256 tierId,
        uint256 durationSeconds,
        uint256 priceWei,
        bool active,
        string calldata label
    ) external onlyOwner {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        if (durationSeconds < MIN_DURATION || durationSeconds > MAX_DURATION) {
            revert InvalidDuration();
        }
        if (priceWei == 0) revert InvalidPrice();

        _tiers[tierId] = Tier({
            durationSeconds: durationSeconds,
            priceWei: priceWei,
            active: active,
            label: label
        });

        emit TierUpdated(tierId, durationSeconds, priceWei);
    }

    /// @notice Disable a tier without deleting it (preserves tierId indices)
    function deactivateTier(uint256 tierId) external onlyOwner {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        _tiers[tierId].active = false;
        emit TierUpdated(tierId, _tiers[tierId].durationSeconds, _tiers[tierId].priceWei);
    }

    /// @inheritdoc IAccessGateway
    function revokeAccess(address user, bytes32 deviceId) external override onlyOwner {
        registry.deleteSession(user, deviceId);
        emit AccessRevoked(user, deviceId);
    }

    /// @notice Update the treasury address
    function setTreasury(address payable newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    /// @inheritdoc IAccessGateway
    function withdraw() external override onlyOwner nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert WithdrawFailed();

        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit Withdrawn(treasury, amount);
    }

    /// @inheritdoc IAccessGateway
    function togglePause() external override onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
        emit EmergencyPause(paused());
    }

    // =========================================================================
    //                              INTERNAL HELPERS
    // =========================================================================

    /// @dev Validates tierId and returns the tier struct
    function _validateTier(uint256 tierId) internal view returns (Tier memory tier) {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        tier = _tiers[tierId];
        if (!tier.active) revert TierInactive(tierId);
    }

    /// @dev Validates ETH payment amount
    function _validatePayment(uint256 required) internal view {
        if (msg.value < required) revert InsufficientPayment(required, msg.value);
    }

    /// @dev Internal checkAccess without external call overhead
    function _checkAccess(address user, bytes32 deviceId)
        internal
        view
        returns (bool active, uint256 expiresAt)
    {
        expiresAt = registry.getExpiry(user, deviceId);
        active = expiresAt > block.timestamp;
    }

    /// @dev Internal tier creation (used by constructor and addTier)
    function _addTier(uint256 durationSeconds, uint256 priceWei, string memory label) internal {
        if (durationSeconds < MIN_DURATION || durationSeconds > MAX_DURATION) {
            revert InvalidDuration();
        }
        if (priceWei == 0) revert InvalidPrice();

        uint256 newId = _tiers.length;
        _tiers.push(Tier({
            durationSeconds: durationSeconds,
            priceWei: priceWei,
            active: true,
            label: label
        }));

        emit TierUpdated(newId, durationSeconds, priceWei);
    }

    // =========================================================================
    //                              FALLBACK / RECEIVE
    // =========================================================================

    /// @dev Reject plain ETH transfers to prevent accidental deposits
    receive() external payable {
        revert("Use purchaseAccess()");
    }

    fallback() external payable {
        revert("Use purchaseAccess()");
    }
}
