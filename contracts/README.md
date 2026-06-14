# Contracts

A detailed guide for the `contracts/` package in the DePIN Access Protocol.

## Overview

This folder contains the core on-chain protocol for time-boxed network access:

- `src/AccessGateway.sol` — the user-facing payment and session management contract.
- `src/SessionRegistry.sol` — a separate data store for session state.
- `src/interfaces/IAccessGateway.sol` — shared interface, events, and custom errors.
- `script/DeployGateway.s.sol` — Foundry deployment and admin scripts.

The contracts are built with Foundry and designed to keep business logic separate from persistent session storage, enabling safer upgrades and verifiable session history.

## Contract Architecture

### AccessGateway

`AccessGateway` is the main protocol entry point. It handles:

- Purchase and extension of time-limited access sessions.
- Tier management (`addTier`, `updateTier`, `deactivateTier`).
- Owner-only emergency operations (`revokeAccess`, `withdraw`, `togglePause`).
- Revenue accounting and overpayment refunds.

Security primitives used:

- `ReentrancyGuard` for all payable functions.
- `Pausable` to halt new purchases and extensions.
- `Ownable2Step` to prevent accidental ownership loss.
- Pull-based withdrawals: ETH is held in contract until owner calls `withdraw()`.

Default deployed tiers:

- `1 Hour` — `1 ether / 1000` (0.001 ETH)
- `6 Hours` — `5 ether / 1000` (0.005 ETH)
- `24 Hours` — `15 ether / 1000` (0.015 ETH)
- `7 Days` — `80 ether / 1000` (0.08 ETH)

### SessionRegistry

`SessionRegistry` is a pure storage contract. The gateway contract is authorized to mutate session state and the owner may reassign it for upgrades.

Key responsibilities:

- Store session records keyed by `(user, deviceId)`.
- Track `expiresAt`, `tierId`, `totalPaid`, and `purchaseCount`.
- Maintain enumeration helpers for off-chain workers.
- Provide view helpers like `getExpiry`, `isActive`, and `remainingSeconds`.

The registry prevents unauthorized state writes using the `onlyGateway` modifier.

### IAccessGateway

The interface defines:

- `Tier` struct
- `purchaseAccess`, `extendAccess`, `checkAccess`, `remainingTime`, `getTier`, `getAllTiers`
- `revokeAccess`, `withdraw`, `togglePause`
- Events used by the off-chain worker: `AccessGranted`, `AccessExtended`, `AccessRevoked`, `TierUpdated`, `Withdrawn`, `EmergencyPause`
- Custom errors for gas-efficient reverts.

## Deployment

### Environment

The `contracts/foundry.toml` file configures Foundry for this workspace:

- `src = "src"`
- `out = "out"`
- `libs = ["lib"]`
- `fs_permissions` allow the deploy script to write deployment output.

### Deploy script

Use the Foundry script in `script/DeployGateway.s.sol` to deploy both contracts and wire them together.

```bash
cd contracts
forge script script/DeployGateway.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Optional verification:

```bash
forge script script/DeployGateway.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_API_KEY
```

### Script helpers

The deploy script also exposes convenience functions for owner operations:

- `addTier(address,uint256,uint256,string)` — add a custom tier.
- `pause(address)` — toggle the gateway pause state.
- `withdrawRevenue(address)` — withdraw contract balance to treasury.

Example:

```bash
forge script script/DeployGateway.s.sol:AddTier \
  --sig "run(address,uint256,uint256,string)" \
  $GATEWAY 1800 500000000000000 "30 Minutes" \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Usage

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

### Fuzz tests

```bash
forge test --match-path "test/fuzz/*" -vvv
```

### Format

```bash
forge fmt
```

### Local node

```bash
anvil
```

## Smart Contract Flows

### purchaseAccess

A user calls `purchaseAccess(deviceId, tierId)` with ETH.

- Validates tier exists and is active.
- Ensures sufficient payment.
- Rejects if a valid session already exists for the same `(user, deviceId)`.
- Writes the session to `SessionRegistry`.
- Emits `AccessGranted`.
- Refunds any overpayment.

### extendAccess

A user calls `extendAccess(deviceId, tierId)` with ETH.

- Validates tier exists and is active.
- Requires an existing session record.
- Adds duration on top of the current expiry or `block.timestamp`.
- Writes extension metadata to `SessionRegistry`.
- Emits `AccessExtended`.
- Refunds any overpayment.

### revokeAccess

Owner-only emergency function to delete a session from `SessionRegistry` and emit `AccessRevoked`.

### withdraw

Owner-only function to send the contract balance to `treasury`. Uses `.call` and reverts on failure.

### togglePause

Toggles purchase and extension availability. Emits `EmergencyPause` with the new paused state.

## SessionRegistry Enumeration

The registry supports off-chain worker indexing by exposing:

- `totalUsers()`
- `userAt(uint256)`
- `getDevicesForUser(address)`
- `getActiveSessions()`

`getActiveSessions()` is intentionally `O(n)` and should only be used off-chain.

## Security Notes

- `receive()` and `fallback()` reject direct ETH transfers.
- `MIN_DURATION`, `MAX_DURATION`, and `MAX_TIERS` bound tier creation.
- `Ownable2Step` covers both contracts for safe ownership transfer.
- `SessionRegistry` uses a separate gateway authorization layer.

## Recommended Workflow

1. Deploy `SessionRegistry` and `AccessGateway` via `DeployGateway.s.sol`.
2. Set `gateway` in `SessionRegistry` to the deployed `AccessGateway`.
3. Use the frontend and gateway worker to interact with `AccessGateway` events.
4. Manage tiers and emergency controls through owner-only scripts.
