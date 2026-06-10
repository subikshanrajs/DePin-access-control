// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SessionRegistry
/// @notice Pure data storage for session state. Decoupled from logic so the
///         AccessGateway contract can be upgraded without losing historical data.
/// @dev Only the authorized gateway (set at deploy time) may write to this contract.
///      The owner may reassign the gateway address if the logic contract is upgraded.
contract SessionRegistry is Ownable, Ownable2Step {
    // =========================================================================
    //                              STRUCTS
    // =========================================================================

    struct Session {
        uint256 expiresAt;  // Unix timestamp
        uint256 tierId;     // Tier used for the most recent purchase
        uint256 totalPaid;  // Cumulative ETH paid across all purchases (wei)
        uint256 purchaseCount; // Number of purchases made
    }

    // =========================================================================
    //                              STORAGE
    // =========================================================================

    /// @dev user address => deviceId => Session
    mapping(address => mapping(bytes32 => Session)) private _sessions;

    /// @dev Flat list of all (user, deviceId) pairs — used for enumeration by the worker
    address[] private _sessionUsers;
    mapping(address => bytes32[]) private _userDevices;
    mapping(address => mapping(bytes32 => bool)) private _deviceRegistered;

    /// @notice The gateway contract authorized to write sessions
    address public gateway;

    // =========================================================================
    //                              EVENTS
    // =========================================================================

    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);
    event SessionWritten(address indexed user, bytes32 indexed deviceId, uint256 expiresAt);
    event SessionDeleted(address indexed user, bytes32 indexed deviceId);

    // =========================================================================
    //                              ERRORS
    // =========================================================================

    error NotGateway(address caller);
    error ZeroAddress();

    // =========================================================================
    //                              MODIFIERS
    // =========================================================================

    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    function _onlyGateway() internal view {
        if (msg.sender != gateway) revert NotGateway(msg.sender);
    }

    // =========================================================================
    //                              CONSTRUCTOR
    // =========================================================================

    /// @param initialOwner  Deployer / multisig that controls governance
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
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
    //                              GATEWAY MANAGEMENT
    // =========================================================================

    /// @notice Authorize a new gateway address (owner only)
    /// @dev    Call this after deploying a new AccessGateway to migrate write access
    function setGateway(address newGateway) external onlyOwner {
        if (newGateway == address(0)) revert ZeroAddress();
        address old = gateway;
        gateway = newGateway;
        emit GatewayUpdated(old, newGateway);
    }

    // =========================================================================
    //                              WRITE FUNCTIONS (gateway only)
    // =========================================================================

    /// @notice Create or overwrite a session record
    function upsertSession(
        address user,
        bytes32 deviceId,
        uint256 expiresAt,
        uint256 tierId,
        uint256 paidWei
    ) external onlyGateway {
        Session storage s = _sessions[user][deviceId];

        // Track unique (user, device) combos for enumeration
        if (!_deviceRegistered[user][deviceId]) {
            _deviceRegistered[user][deviceId] = true;
            // Add user to flat list if first device
            if (_userDevices[user].length == 0) {
                _sessionUsers.push(user);
            }
            _userDevices[user].push(deviceId);
        }

        s.expiresAt = expiresAt;
        s.tierId = tierId;
        s.totalPaid += paidWei;
        s.purchaseCount += 1;

        emit SessionWritten(user, deviceId, expiresAt);
    }

    /// @notice Extend an existing session (adds duration on top of current expiry)
    function extendSession(
        address user,
        bytes32 deviceId,
        uint256 additionalSeconds,
        uint256 tierId,
        uint256 paidWei
    ) external onlyGateway {
        Session storage s = _sessions[user][deviceId];

        // Extend from max(now, current expiry) to prevent buying time "in the past"
        uint256 base = s.expiresAt > block.timestamp ? s.expiresAt : block.timestamp;
        s.expiresAt = base + additionalSeconds;
        s.tierId = tierId;
        s.totalPaid += paidWei;
        s.purchaseCount += 1;

        emit SessionWritten(user, deviceId, s.expiresAt);
    }

    /// @notice Delete a session record entirely (for revocations)
    function deleteSession(address user, bytes32 deviceId) external onlyGateway {
        delete _sessions[user][deviceId];
        emit SessionDeleted(user, deviceId);
    }

    // =========================================================================
    //                              READ FUNCTIONS
    // =========================================================================

    /// @notice Fetch full session data
    function getSession(address user, bytes32 deviceId)
        external
        view
        returns (Session memory)
    {
        return _sessions[user][deviceId];
    }

    /// @notice Quick expiry check — returns 0 if not found or expired
    function getExpiry(address user, bytes32 deviceId) external view returns (uint256) {
        return _sessions[user][deviceId].expiresAt;
    }

    /// @notice Returns true if the session is currently valid
    function isActive(address user, bytes32 deviceId) external view returns (bool) {
        return _sessions[user][deviceId].expiresAt > block.timestamp;
    }

    /// @notice Returns remaining seconds (0 if expired)
    function remainingSeconds(address user, bytes32 deviceId) external view returns (uint256) {
        uint256 expiry = _sessions[user][deviceId].expiresAt;
        if (expiry <= block.timestamp) return 0;
        return expiry - block.timestamp;
    }

    // =========================================================================
    //                              ENUMERATION
    // =========================================================================

    /// @notice Total number of unique users who have ever had a session
    function totalUsers() external view returns (uint256) {
        return _sessionUsers.length;
    }

    /// @notice Get user address by index (for iteration)
    function userAt(uint256 index) external view returns (address) {
        return _sessionUsers[index];
    }

    /// @notice Get all device IDs for a user
    function getDevicesForUser(address user) external view returns (bytes32[] memory) {
        return _userDevices[user];
    }

    /// @notice Get all currently active sessions — WARNING: O(n), use only off-chain
    function getActiveSessions()
        external
        view
        returns (address[] memory users, bytes32[] memory deviceIds, uint256[] memory expiries)
    {
        uint256 total;
        uint256 userCount = _sessionUsers.length;

        // First pass: count active sessions
        for (uint256 i = 0; i < userCount; i++) {
            address u = _sessionUsers[i];
            bytes32[] memory devices = _userDevices[u];
            for (uint256 j = 0; j < devices.length; j++) {
                if (_sessions[u][devices[j]].expiresAt > block.timestamp) {
                    total++;
                }
            }
        }

        users = new address[](total);
        deviceIds = new bytes32[](total);
        expiries = new uint256[](total);
        uint256 idx;

        // Second pass: populate arrays
        for (uint256 i = 0; i < userCount; i++) {
            address u = _sessionUsers[i];
            bytes32[] memory devices = _userDevices[u];
            for (uint256 j = 0; j < devices.length; j++) {
                Session memory s = _sessions[u][devices[j]];
                if (s.expiresAt > block.timestamp) {
                    users[idx] = u;
                    deviceIds[idx] = devices[j];
                    expiries[idx] = s.expiresAt;
                    idx++;
                }
            }
        }
    }
}
