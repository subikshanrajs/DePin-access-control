# NetPass — DePIN Access Protocol

**Decentralized, time-boxed network access on Arbitrum.** Pay ETH, get instant Wi-Fi access for a fixed duration. No accounts, no passwords, no centralized billing — just a wallet and a smart contract.

```
┌──────────────────┐   1. Pay ETH (purchaseAccess)   ┌───────────────────────────┐
│   User Frontend   │ ───────────────────────────────▶│   AccessGateway.sol        │
│  (React + wagmi)  │◀─────────────────────────────── │   (tiers, sessions, pause)  │
└──────────────────┘   2. Emits AccessGranted event   └───────────────────────────┘
                                                                    │
                                                                    │ writes session
                                                                    ▼
                                                        ┌───────────────────────────┐
                                                        │   SessionRegistry.sol      │
                                                        │   (pure data store)        │
                                                        └───────────────────────────┘
                                                                    ▲
                                                                    │ 3. listens for events
                                                        ┌───────────────────────────┐
                                                        │  Gateway Worker (Node.js)   │
                                                        │  viem event listener        │
                                                        └───────────────────────────┘
                                                                    │
                                                                    │ 4. configures hardware
                                                                    ▼
                                                        ┌───────────────────────────┐
                                                        │  Router / RADIUS / Sim      │
                                                        │  (grants or revokes access) │
                                                        └───────────────────────────┘
```

---

## Table of Contents

- [Overview](#overview)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Smart Contract Architecture](#smart-contract-architecture)
- [Security Properties](#security-properties)
- [Pricing Tiers](#pricing-tiers)
- [Getting Started](#getting-started)
- [Testing](#testing)
- [Deployment to Arbitrum Sepolia](#deployment-to-arbitrum-sepolia)
- [Operator Commands](#operator-commands)
- [Hardware Integration](#hardware-integration)
- [Troubleshooting](#troubleshooting)
- [Demo Recording Guide](#demo-recording-guide)
- [Roadmap / Future Work](#roadmap--future-work)

---

## Overview

NetPass is a **DePIN (Decentralized Physical Infrastructure Network) access control protocol**. It lets anyone monetize a Wi-Fi network, hotspot, or any gated physical resource using on-chain, ETH-denominated time passes — no user accounts, no payment processor, no centralized session database.

**The flow:**

1. A user connects their wallet and picks a tier (e.g. "1 Hour — 0.001 ETH").
2. They call `purchaseAccess()`, sending ETH directly to the `AccessGateway` contract.
3. The contract records the session's expiry timestamp in `SessionRegistry` and emits an `AccessGranted` event.
4. An off-chain **Gateway Worker** (Node.js) listens for this event in real time.
5. The worker translates the event into a hardware command — e.g. adding the device's MAC address to a router's allowlist (or, in `simulation` mode, just logging what *would* happen).
6. When the session expires, the worker (via a polling safety net) revokes access automatically.

Everything is verifiable on-chain. The blockchain is the source of truth — the worker rebuilds its session cache from chain events on every restart.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity 0.8.24, Foundry, OpenZeppelin v5 |
| Off-chain Worker | Node.js 20+, viem, winston |
| Frontend | React 18, Vite, wagmi v2, viem, TanStack Query |
| Network | Arbitrum Sepolia (testnet) / Arbitrum One (mainnet) |
| Hardware (optional) | OpenWrt (UCI/SSH), FreeRADIUS (REST API), or simulation |

---

## Project Structure

```
Depin-accessctrl/
│
├── README.md                          ← you are here
│
├── contracts/                         # Foundry workspace
│   ├── foundry.toml                   # Compiler config, RPC endpoints, fuzz settings
│   ├── remappings.txt                 # Import path mappings (OZ, forge-std)
│   ├── .env                           # PRIVATE_KEY, RPC URLs, Arbiscan key (gitignored)
│   ├── lib/                           # forge-std, openzeppelin-contracts
│   │
│   ├── src/
│   │   ├── interfaces/
│   │   │   └── IAccessGateway.sol     # Structs, events, errors, function signatures
│   │   ├── AccessGateway.sol          # Core logic: payments, tiers, pause, withdraw
│   │   └── SessionRegistry.sol        # Pure data store for session state
│   │
│   ├── script/
│   │   └── DeployGateway.s.sol        # Deploy + addTier/pause/withdraw helper scripts
│   │
│   ├── test/
│   │   ├── AccessGateway.t.sol        # 35 unit tests
│   │   └── fuzz/
│   │       └── FuzzAccessGateway.t.sol # 8 property-based fuzz tests
│   │
│   └── deployments/
│       └── latest.json                # Deployed contract addresses (gitignored)
│
├── gateway-worker/                    # Off-chain IoT daemon (Node.js)
│   ├── package.json
│   ├── .env                           # RPC, contract address, router backend (gitignored)
│   └── src/
│       ├── index.js                   # Event listener + session manager + poller
│       ├── routerCmd.js               # Hardware backends: simulation/openwrt/radius
│       └── logger.js                  # Structured winston logger
│
└── frontend/                          # React + wagmi + viem UI
    ├── package.json
    ├── vite.config.js
    ├── index.html
    ├── .env.local                     # Contract addresses (gitignored)
    └── src/
        ├── main.jsx                   # React entry point
        ├── App.jsx                    # Main UI (wallet connect, tiers, session card)
        ├── index.css                  # Dark "infrastructure" theme
        ├── lib/
        │   └── config.js              # Wagmi config + contract ABI + addresses
        └── hooks/
            └── useAccessGateway.js     # React hooks for reads/writes/countdown
```

---

## Smart Contract Architecture

### `AccessGateway.sol` — Core Logic

The single user-facing entry point.

| Function | Description |
|---|---|
| `purchaseAccess(bytes32 deviceId, uint256 tierId)` | Pay ETH for a new session. Reverts if a session is already active for this device. |
| `extendAccess(bytes32 deviceId, uint256 tierId)` | Top up an existing session. Adds duration on top of current (or expired) expiry. |
| `checkAccess(address user, bytes32 deviceId)` | View function — returns `(active, expiresAt)`. |
| `remainingTime(address user, bytes32 deviceId)` | View function — seconds remaining (0 if expired). |
| `getAllTiers()` / `getTier(uint256)` | View pricing tiers. |
| `addTier`, `updateTier`, `deactivateTier` | Owner-only tier management. |
| `revokeAccess(user, deviceId)` | Owner-only emergency revocation. |
| `withdraw()` | Owner-only — sends accumulated ETH to `treasury`. |
| `togglePause()` | Owner-only emergency stop (blocks new purchases). |

### `SessionRegistry.sol` — Data Storage

A pure key-value store for `(user, deviceId) → Session { expiresAt, tierId, totalPaid, purchaseCount }`. Decoupled from `AccessGateway` so the logic contract can be replaced/upgraded in the future without losing historical session data — the registry's `gateway` address is reassignable by its owner.

### `IAccessGateway.sol` — Interface

Defines all structs (`Tier`), events (`AccessGranted`, `AccessExtended`, `AccessRevoked`, `TierUpdated`, `Withdrawn`, `EmergencyPause`), and custom errors used throughout.

---

## Security Properties

- **`ReentrancyGuard`** — `nonReentrant` on `purchaseAccess` and `extendAccess`. Verified by a dedicated reentrancy test using an attacker contract that overpays to trigger the refund callback.
- **`Ownable2Step`** — two-step ownership transfer; an owner can't accidentally "brick" the contract by transferring to a typo'd address (the new owner must explicitly `acceptOwnership()`).
- **`Pausable`** — `togglePause()` halts `purchaseAccess`/`extendAccess` in an emergency without needing to redeploy.
- **Pull-over-push payments** — ETH accumulates in the contract; the owner explicitly calls `withdraw()`. No automatic outbound transfers except overpayment refunds (which use `.call` with checked return value).
- **Checks-Effects-Interactions** — session state is written to `SessionRegistry` *before* any external call or event emission.
- **No oracles** — prices are owner-set in ETH directly. No price-feed manipulation surface.
- **Integer-only arithmetic** — no floating point; `remainingTime` is guarded against underflow.
- **Bounded loops** — `MAX_TIERS = 32` prevents unbounded gas costs in tier iteration.


---

## Pricing Tiers

Seeded at deployment (owner can add/update/deactivate any time via `addTier` / `updateTier` / `deactivateTier`):

| Tier ID | Label | Duration | Price |
|---|---|---|---|
| 0 | 1 Hour | 3,600 sec | 0.0010 ETH |
| 1 | 6 Hours | 21,600 sec | 0.0050 ETH |
| 2 | 24 Hours | 86,400 sec | 0.0150 ETH |
| 3 | 7 Days | 604,800 sec | 0.0800 ETH |

Tiers are bounded: `MIN_DURATION = 60s`, `MAX_DURATION = 30 days`, `MAX_TIERS = 32`.

---

## Getting Started

### 1. Prerequisites

- **Foundry** (forge, cast, anvil):
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  forge --version
  ```
- **Node.js 20+** for the worker, **Node 18+** for the frontend
- A **dedicated dev wallet** (do not use your main wallet) funded with Arbitrum Sepolia ETH:
  - https://faucet.triangleplatform.com/arbitrum/sepolia
  - https://www.alchemy.com/faucets/arbitrum-sepolia
- (Optional) A free **Arbiscan API key** from https://sepolia.arbiscan.io → My Profile → API Keys, for contract verification


### 2. Smart Contracts (Foundry)

```bash
cd contracts

# Install dependencies
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit

# Build
forge build
```

Create `contracts/.env`:

```bash
# Must be 0x-prefixed — vm.envUint() requires the hex prefix
PRIVATE_KEY=0xYOUR_PRIVATE_KEY_HERE

ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
ARBISCAN_API_KEY=YOUR_ARBISCAN_KEY   # optional, for --verify

# Optional overrides — default to deployer wallet if unset
# DEPLOY_OWNER=0x...
# DEPLOY_TREASURY=0x...
```

```bash
source .env
mkdir -p deployments

# Sanity checks
cast wallet address --private-key $PRIVATE_KEY
cast balance $(cast wallet address --private-key $PRIVATE_KEY) \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --ether
```

### 3. Off-chain Worker

```bash
cd gateway-worker
npm install
cp .env.example .env
```

Edit `.env`:

```bash
RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
ACCESS_GATEWAY_ADDRESS=0xYourDeployedGatewayAddress
ROUTER_BACKEND=simulation     # simulation | openwrt | radius
POLL_INTERVAL_MS=30000
START_BLOCK=<your deployment block number>   # avoids scanning from genesis
```

```bash
npm start
```

### 4. Frontend

```bash
cd frontend
npm install
cp .env.example .env.local
```

Edit `.env.local`:

```bash
VITE_GATEWAY_ADDRESS_TESTNET=0xYourDeployedGatewayAddress
VITE_REGISTRY_ADDRESS_TESTNET=0xYourDeployedRegistryAddress
VITE_WALLETCONNECT_PROJECT_ID=   # optional, leave blank if only using MetaMask
```

```bash
npm run dev
# → http://localhost:5173
```

---

## Testing

```bash
cd contracts

# All unit tests
forge test -vvv

# Fuzz tests only (property-based, 256+ runs each)
forge test --match-path "test/fuzz/*" -vvv

# Gas report
forge test --gas-report

# Run a single test
forge test --match-test test_PurchaseAccess_1Hour -vvvv
```

**Expected result: 43/43 tests passing** — 35 unit tests + 8 fuzz tests.

### What's covered

- ✅ Purchase, extend, overpayment refund, multi-user/multi-tier sessions
- ✅ All revert paths: insufficient payment, invalid/inactive tier, double-purchase, paused state
- ✅ Owner admin: add/update/deactivate tiers, revoke access, withdraw, pause/unpause
- ✅ `Ownable2Step` two-step transfer on `SessionRegistry`
- ✅ Registry write isolation (`onlyGateway` modifier)
- ✅ Reentrancy guard (verified via an attacker contract that overpays to trigger the refund-driven re-entry attempt)
- ✅ Fuzz: payment integrity (over/underpayment), expiry-timestamp exactness, no underflow in `remainingTime`, extension monotonicity, revenue accounting, tier-bounds validation

### Local fork testing (optional)

```bash
# Terminal 1
anvil --fork-url https://sepolia-rollup.arbitrum.io/rpc --chain-id 421614

# Terminal 2
forge test --rpc-url http://127.0.0.1:8545 -vvv
```

---

## Deployment to Arbitrum Sepolia

```bash
cd contracts
source .env

forge script script/DeployGateway.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_API_KEY
```

This deploys **two contracts** and wires them together in one script:

1. `SessionRegistry` (data store)
2. `AccessGateway` (logic, seeded with the 4 default tiers)
3. Calls `registry.setGateway(address(gateway))` to authorize writes

Output is saved to `deployments/latest.json`:

```json
{
  "chainId": 421614,
  "blockNumber": 11041995,
  "SessionRegistry": "0x93AC75501554B258ccd9b6a55D5e8CfE95198572",
  "AccessGateway": "0xef7cc55FE427e43c55Ee6Ba0f86B5016F1a6Dd4b",
  "owner": "0x13BCceB92E0c206eD518A6Caab90c0C422e76C83",
  "treasury": "0x13BCceB92E0c206eD518A6Caab90c0C422e76C83"
}
```

### Verify on Arbiscan

If `--verify` succeeds, your source is published at:

```
https://sepolia.arbiscan.io/address/<AccessGateway address>#code
```

Use the **Read Contract** tab to call `getTier(0)`, `tierCount()`, etc. directly from the browser — this avoids `cast` ABI-decoding quirks with struct returns (see [Troubleshooting](#troubleshooting)).

### Wire up worker + frontend

Copy `AccessGateway` (and `SessionRegistry`, for the frontend) addresses into:

- `gateway-worker/.env` → `ACCESS_GATEWAY_ADDRESS`
- `frontend/.env.local` → `VITE_GATEWAY_ADDRESS_TESTNET`, `VITE_REGISTRY_ADDRESS_TESTNET`

---

## Operator Commands

```bash
cd contracts && source .env

# Add a custom tier (30 minutes @ 0.0005 ETH)
forge script script/DeployGateway.s.sol \
  --sig "addTier(address,uint256,uint256,string)" \
  $GATEWAY 1800 500000000000000 "30 Minutes" \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Emergency pause / unpause (toggles)
forge script script/DeployGateway.s.sol \
  --sig "pause(address)" $GATEWAY \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Withdraw accumulated ETH to treasury
forge script script/DeployGateway.s.sol \
  --sig "withdrawRevenue(address)" $GATEWAY \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

---

## Hardware Integration

The worker's `routerCmd.js` supports three backends via `ROUTER_BACKEND` in `.env`:

### `simulation` (default — no hardware required)

Logs the exact command that *would* be run, e.g.:

```
[SIM] GRANT ACCESS {
  deviceId: '0xeb1101...',
  wallet: '0x13BCce...',
  expiry: '2026-06-12T14:26:24.000Z',
  ttlSeconds: 3599,
  simulatedCommand: 'iptables -I FORWARD -m mac --mac-source XX:XX:XX:XX:XX:XX -j ACCEPT'
}
```

Perfect for demos and development — proves the full event-driven loop without owning a router.

### `openwrt`

SSHes into an OpenWrt router and manages a MAC-address allowlist via UCI (`uci add_list wireless.@wifi-iface[0].maclist=...`, `wifi reload`). Configure:

```bash
ROUTER_BACKEND=openwrt
OPENWRT_HOST=192.168.1.1
OPENWRT_USER=root
OPENWRT_PASSWORD=yourpassword   # use SSH keys in production instead
OPENWRT_INTERFACE=wlan0
```

### `radius`

Creates/deletes user entries in FreeRADIUS via its REST API — works with enterprise APs (UniFi, Cisco, etc.):

```bash
ROUTER_BACKEND=radius
RADIUS_HOST=127.0.0.1
RADIUS_PORT=8080
RADIUS_SECRET=testing123
```

### Device Identity

The contract stores `bytes32 deviceId = keccak256(identifier)`. The frontend defaults `deviceId` to the connected **wallet address** (one device per wallet) — the "Custom device" field lets a user instead enter a MAC address or other identifier for a *different* physical device. In production, maintain a `deviceId → MAC address` mapping in a small database; the smart contract only ever sees the hash.

---

## Troubleshooting

Issues encountered (and fixed) during development of this project — kept here as a reference.

### `forge test` — `OwnableInvalidOwner` vs `ZeroAddress`

```
[FAIL: Error != expected error: OwnableInvalidOwner(0x000...) != ZeroAddress()]
```

OpenZeppelin's `Ownable(_owner)` base constructor runs **before** `AccessGateway`'s constructor body. If `_owner == address(0)`, OZ's own check fires first with `OwnableInvalidOwner(address(0))` — the contract's custom `ZeroAddress()` check is never reached. **Fixed** by updating `test_Constructor_RejectsZeroOwner` to expect `OwnableInvalidOwner(address(0))`.

### `forge test` — reentrancy test "next call did not revert as expected"

The original attacker contract sent the *exact* tier price, so `excess == 0` and the refund `.call{value: excess}("")` was skipped — meaning the attacker's `receive()` (where the re-entrant call lives) was never invoked, so nothing reverted. **Fixed** by having the attacker **overpay**, triggering the refund path → `receive()` → re-entrant `purchaseAccess` call → blocked by `nonReentrant` → refund `.call` returns `false` → outer call reverts with `WithdrawFailed()`.

### `vm.envUint: failed parsing $PRIVATE_KEY ... missing hex prefix ("0x")`

`PRIVATE_KEY` in `.env` must be `0x`-prefixed:

```bash
PRIVATE_KEY=0xabcd1234...   # correct
PRIVATE_KEY=abcd1234...     # incorrect — will fail to parse
```

### `cast call ... getTier(uint256)(uint256,uint256,bool,string)` → "buffer overrun while deserializing"

Functions returning a **single struct** need the return type wrapped in an extra tuple layer for `cast`:

```bash
# incorrect — treats the struct's 4 fields as 4 top-level returns
cast call $GATEWAY "getTier(uint256)(uint256,uint256,bool,string)" 0 --rpc-url $RPC

# correct — one return value that is itself a tuple
cast call $GATEWAY "getTier(uint256)((uint256,uint256,bool,string))" 0 --rpc-url $RPC
```

Or simply use Arbiscan's **Read Contract** tab — no ABI-string gymnastics required.

### `npm start` → `Cannot find package 'viem'` / `vite: not found`

`node_modules` was never installed. Run `npm install` before `npm start` / `npm run dev` in both `gateway-worker` and `frontend`.

### `npm install` → `ENOTEMPTY: directory not empty, rename ... node_modules/react -> .react-XXXX`

Classic **WSL + `/mnt/c/...` filesystem bug**. npm's atomic rename operations during install don't survive the 9P filesystem bridge reliably. **Fix:** move the project to your Linux home directory:

```bash
cp -r /mnt/c/Users/<you>/Projects/Depin-accessctrl ~/Depin-accessctrl
cd ~/Depin-accessctrl/frontend
rm -rf node_modules package-lock.json
npm install
```

Repeat for `gateway-worker`. Work from `~/Depin-accessctrl` going forward (open it in VS Code via the WSL Remote extension if needed).

### MetaMask — "Failed transaction: max fee per gas less than block base fee"

```
maxFeePerGas: 20092000 base
```

Transient Arbitrum Sepolia gas-estimation lag — MetaMask quoted a `maxFeePerGas` below the *current* block's base fee. The transaction fails **before** reaching the contract (no funds spent, `purchaseAccess` never executed). **Fix:** simply retry. If it persists, edit the gas fee in MetaMask's confirmation popup to a higher value, or switch to a dedicated RPC (Alchemy/Infura) instead of the public `sepolia-rollup.arbitrum.io/rpc` endpoint.

---

## Demo Recording Guide

A clean ~90-second flow that demonstrates the full on-chain → off-chain → "hardware" loop:

1. **Intro** (5s) — briefly show the architecture diagram, narrate: *"User pays ETH → smart contract on Arbitrum tracks expiry → off-chain worker would configure a router."*
2. **Connect wallet** — MetaMask on Arbitrum Sepolia.
3. **Select a tier** (e.g. "1 Hour — 0.0010 ETH") → click **Buy**.
4. **Confirm in MetaMask** — show the transaction being signed.
5. **Cut to the worker terminal** — within seconds, the `AccessGranted` event log and `[SIM] GRANT ACCESS` line appear, including the simulated `iptables` MAC-filter command and computed expiry.
6. **Cut back to the frontend** — session card now shows **Active**, a live countdown (`59m 33s remaining`), and the expiry timestamp.
7. *(Optional)* Open the **Arbiscan Events tab** for the `AccessGateway` address — show the `AccessGranted` event with raw on-chain `user`, `deviceId`, `tierId`, `expiresAt`, `amountPaid` as independent proof.
8. *(Optional)* Click **Extend for 1 hr** — show the countdown jump up and a second `AccessExtended` event logged by the worker.

**Recording tools:** OBS Studio (free, cross-platform) or Windows Game Bar (`Win+G`) — tile the browser, worker terminal, and (optionally) Arbiscan side by side.

**Device ID field:** leave it blank for the demo — it defaults to your connected wallet address (one device per wallet), which is the simplest and clearest story to tell. The "Custom device" field exists for granting access to a *different* physical device (e.g. via MAC address) and is worth mentioning if asked about real-world deployment, without needing to demo it live.

**If a transient gas error appears mid-recording:** just say *"testnet gas estimation occasionally lags — let's retry"* and click again. This is a well-known, expected occurrence on public L2 testnets.

---

## Roadmap / Future Work

- [ ] Multisig (Gnosis Safe) ownership for mainnet deployment
- [ ] Persistent `deviceId -> MAC address` mapping database for the worker
- [ ] WebSocket RPC for instant (vs. polled) event delivery
- [ ] Retry queue with exponential backoff for failed hardware provisioning
- [ ] Prometheus metrics endpoint (`prom-client` already included in worker deps)
- [ ] On-chain referral/affiliate tier for hotspot operators
- [ ] Mobile-optimized frontend / PWA for captive-portal style access
- [ ] Optional ERC-20 payment support (stablecoins) alongside native ETH

---

## License

MIT