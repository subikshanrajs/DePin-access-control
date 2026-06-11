/**
 * DePIN Gateway Worker — Main Daemon
 *
 * This is the off-chain bridge between the AccessGateway smart contract
 * and physical network hardware (OpenWrt routers, RADIUS servers, etc.).
 *
 * Architecture:
 *   1. EVENT-DRIVEN:  Subscribes to AccessGranted / AccessRevoked events via
 *      WebSocket (viem watchContractEvent). Immediately provisions hardware
 *      when a new session is purchased.
 *
 *   2. POLL-BASED:    A background loop checks for expired sessions every
 *      POLL_INTERVAL_MS. This is the safety net for any missed events.
 *
 *   3. STARTUP SYNC:  On boot, reads all historical events to reconstruct
 *      the current session state without trusting any local database.
 *
 * The worker maintains an in-memory session map for fast expiry checks.
 * This map is always rebuilt from chain on restart — it is NOT the source
 * of truth, the blockchain is.
 */

import 'dotenv/config';
import { createPublicClient, createWalletClient, webSocket, http, parseAbiItem } from 'viem';
import { arbitrumSepolia, arbitrum } from 'viem/chains';
import { RouterBackend } from './routerCmd.js';
import { createLogger } from './logger.js';

// ============================================================================
//                           CONFIGURATION
// ============================================================================

const config = {
  rpcUrl:           process.env.RPC_URL            || 'http://127.0.0.1:8545',
  gatewayAddress:   process.env.ACCESS_GATEWAY_ADDRESS,
  registryAddress:  process.env.SESSION_REGISTRY_ADDRESS,
  pollIntervalMs:   parseInt(process.env.POLL_INTERVAL_MS   || '30000'),
  blockConfirms:    parseInt(process.env.BLOCK_CONFIRMATIONS || '1'),
  startBlock:       BigInt(process.env.START_BLOCK          || '0'),
  routerBackend:    process.env.ROUTER_BACKEND              || 'simulation',
  logLevel:         process.env.LOG_LEVEL                   || 'info',
};

if (!config.gatewayAddress) {
  console.error('FATAL: ACCESS_GATEWAY_ADDRESS is not set in .env');
  process.exit(1);
}

// ============================================================================
//                           CONTRACT ABI (minimal)
// ============================================================================

const GATEWAY_ABI = [
  // Events
  {
    type: 'event',
    name: 'AccessGranted',
    inputs: [
      { name: 'user',       type: 'address', indexed: true  },
      { name: 'deviceId',   type: 'bytes32', indexed: true  },
      { name: 'tierId',     type: 'uint256', indexed: true  },
      { name: 'expiresAt',  type: 'uint256', indexed: false },
      { name: 'amountPaid', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'AccessRevoked',
    inputs: [
      { name: 'user',     type: 'address', indexed: true },
      { name: 'deviceId', type: 'bytes32', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'AccessExtended',
    inputs: [
      { name: 'user',         type: 'address', indexed: true  },
      { name: 'deviceId',     type: 'bytes32', indexed: true  },
      { name: 'newExpiresAt', type: 'uint256', indexed: false },
      { name: 'amountPaid',   type: 'uint256', indexed: false },
    ],
  },
  // Read functions
  {
    type: 'function',
    name: 'checkAccess',
    stateMutability: 'view',
    inputs: [
      { name: 'user',     type: 'address' },
      { name: 'deviceId', type: 'bytes32' },
    ],
    outputs: [
      { name: 'active',    type: 'bool'    },
      { name: 'expiresAt', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'remainingTime',
    stateMutability: 'view',
    inputs: [
      { name: 'user',     type: 'address' },
      { name: 'deviceId', type: 'bytes32' },
    ],
    outputs: [{ type: 'uint256' }],
  },
];

// ============================================================================
//                           SESSION MANAGER
// ============================================================================

/**
 * In-memory session cache. The key is `${userAddress}:${deviceId}`.
 * Value: { expiresAt: number (Unix seconds), provisioned: boolean }
 *
 * This is ALWAYS rebuilt from chain on startup. Never use as source of truth.
 */
const sessions = new Map();

function sessionKey(user, deviceId) {
  return `${user.toLowerCase()}:${deviceId}`;
}

function upsertSession(user, deviceId, expiresAt) {
  const key = sessionKey(user, deviceId);
  const existing = sessions.get(key);
  sessions.set(key, {
    user,
    deviceId,
    expiresAt: Number(expiresAt),
    provisioned: existing?.provisioned || false,
  });
}

function removeSession(user, deviceId) {
  sessions.delete(sessionKey(user, deviceId));
}

function getSession(user, deviceId) {
  return sessions.get(sessionKey(user, deviceId));
}

// ============================================================================
//                           MAIN WORKER CLASS
// ============================================================================

class GatewayWorker {
  constructor() {
    this.log    = createLogger(config.logLevel);
    this.router = new RouterBackend(config.routerBackend, this.log);

    // Use HTTP transport for historical queries, WebSocket for live events
    const transport = config.rpcUrl.startsWith('ws')
      ? webSocket(config.rpcUrl)
      : http(config.rpcUrl);

    this.client = createPublicClient({
      transport,
      // Auto-detect chain from RPC; for production pin to arbitrum or arbitrumSepolia
    });
  }

  // --------------------------------------------------------------------------
  //  STARTUP: Replay historical events to reconstruct current state
  // --------------------------------------------------------------------------

  async syncHistoricalEvents() {
    this.log.info('Syncing historical events from block', { startBlock: config.startBlock.toString() });

    const currentBlock = await this.client.getBlockNumber();
    let synced = 0;

    // Fetch all AccessGranted events
    const grantedLogs = await this.client.getLogs({
      address: config.gatewayAddress,
      event: {
        type: 'event',
        name: 'AccessGranted',
        inputs: GATEWAY_ABI[0].inputs,
      },
      fromBlock: config.startBlock,
      toBlock:   currentBlock,
    });

    for (const log of grantedLogs) {
      const { user, deviceId, expiresAt } = log.args;
      upsertSession(user, deviceId, expiresAt);
      synced++;
    }

    // Fetch all AccessExtended events (override expiry)
    const extendedLogs = await this.client.getLogs({
      address: config.gatewayAddress,
      event: {
        type: 'event',
        name: 'AccessExtended',
        inputs: GATEWAY_ABI[2].inputs,
      },
      fromBlock: config.startBlock,
      toBlock:   currentBlock,
    });

    for (const log of extendedLogs) {
      const { user, deviceId, newExpiresAt } = log.args;
      upsertSession(user, deviceId, newExpiresAt);
    }

    // Fetch all AccessRevoked events (remove sessions)
    const revokedLogs = await this.client.getLogs({
      address: config.gatewayAddress,
      event: {
        type: 'event',
        name: 'AccessRevoked',
        inputs: GATEWAY_ABI[1].inputs,
      },
      fromBlock: config.startBlock,
      toBlock:   currentBlock,
    });

    for (const log of revokedLogs) {
      const { user, deviceId } = log.args;
      removeSession(user, deviceId);
    }

    // Now provision all currently-active sessions
    const now = Math.floor(Date.now() / 1000);
    let provisioned = 0;

    for (const [key, session] of sessions) {
      if (session.expiresAt > now) {
        await this.provisionAccess(session.user, session.deviceId, session.expiresAt);
        provisioned++;
      } else {
        sessions.delete(key);
      }
    }

    this.log.info('Historical sync complete', {
      totalEvents: synced,
      activeSessions: provisioned,
      currentBlock: currentBlock.toString(),
    });
  }

  // --------------------------------------------------------------------------
  //  EVENT LISTENERS: Real-time subscription
  // --------------------------------------------------------------------------

  startEventListeners() {
    this.log.info('Starting real-time event listeners');

    // Listen for AccessGranted
    this.client.watchContractEvent({
      address:       config.gatewayAddress,
      abi:           GATEWAY_ABI,
      eventName:     'AccessGranted',
      onLogs:        async (logs) => {
        for (const log of logs) {
          const { user, deviceId, tierId, expiresAt, amountPaid } = log.args;
          this.log.info('AccessGranted event received', {
            user,
            deviceId,
            tierId: tierId.toString(),
            expiresAt: new Date(Number(expiresAt) * 1000).toISOString(),
            amountPaid: `${Number(amountPaid) / 1e18} ETH`,
          });
          upsertSession(user, deviceId, expiresAt);
          await this.provisionAccess(user, deviceId, Number(expiresAt));
        }
      },
      onError: (err) => this.log.error('AccessGranted listener error', { error: err.message }),
    });

    // Listen for AccessExtended
    this.client.watchContractEvent({
      address:   config.gatewayAddress,
      abi:       GATEWAY_ABI,
      eventName: 'AccessExtended',
      onLogs:    async (logs) => {
        for (const log of logs) {
          const { user, deviceId, newExpiresAt } = log.args;
          this.log.info('AccessExtended event received', {
            user,
            deviceId,
            newExpiry: new Date(Number(newExpiresAt) * 1000).toISOString(),
          });
          upsertSession(user, deviceId, newExpiresAt);
          await this.provisionAccess(user, deviceId, Number(newExpiresAt));
        }
      },
      onError: (err) => this.log.error('AccessExtended listener error', { error: err.message }),
    });

    // Listen for AccessRevoked
    this.client.watchContractEvent({
      address:   config.gatewayAddress,
      abi:       GATEWAY_ABI,
      eventName: 'AccessRevoked',
      onLogs:    async (logs) => {
        for (const log of logs) {
          const { user, deviceId } = log.args;
          this.log.info('AccessRevoked event received', { user, deviceId });
          removeSession(user, deviceId);
          await this.revokeAccess(user, deviceId);
        }
      },
      onError: (err) => this.log.error('AccessRevoked listener error', { error: err.message }),
    });

    this.log.info('All event listeners active');
  }

  // --------------------------------------------------------------------------
  //  POLLING: Safety net for missed events
  // --------------------------------------------------------------------------

  startExpiryPoller() {
    this.log.info('Starting expiry poller', { intervalMs: config.pollIntervalMs });

    const poll = async () => {
      const now = Math.floor(Date.now() / 1000);
      let expired = 0;

      for (const [key, session] of sessions) {
        if (session.expiresAt <= now) {
          this.log.info('Session expired (detected by poller)', {
            user: session.user,
            deviceId: session.deviceId,
          });
          await this.revokeAccess(session.user, session.deviceId);
          sessions.delete(key);
          expired++;
        }
      }

      if (expired > 0) {
        this.log.info('Poller cycle: expired sessions cleaned up', { expired });
      }
    };

    setInterval(poll, config.pollIntervalMs);
  }

  // --------------------------------------------------------------------------
  //  HARDWARE OPERATIONS
  // --------------------------------------------------------------------------

  /**
   * Provision access for a device. The router backend is responsible for
   * translating this into the appropriate hardware command (OpenWrt UCI,
   * RADIUS attribute, hostapd reload, etc.)
   *
   * @param {string} user      - Wallet address of the session owner
   * @param {string} deviceId  - bytes32 device identifier from the contract
   * @param {number} expiresAt - Unix timestamp when access expires
   */
  async provisionAccess(user, deviceId, expiresAt) {
    const session = getSession(user, deviceId);
    if (session?.provisioned) {
      this.log.debug('Device already provisioned, updating expiry only', { deviceId });
    }

    try {
      await this.router.grantAccess(user, deviceId, expiresAt);

      // Mark as provisioned in cache
      upsertSession(user, deviceId, expiresAt);
      const s = getSession(user, deviceId);
      if (s) s.provisioned = true;

      this.log.info('Hardware provisioned', {
        deviceId,
        expiresAt: new Date(expiresAt * 1000).toISOString(),
        backend: config.routerBackend,
      });
    } catch (err) {
      this.log.error('Hardware provisioning FAILED', {
        deviceId,
        error: err.message,
        // Do NOT expose stack trace in production logs
      });
      // TODO: implement retry queue with exponential backoff
    }
  }

  /**
   * Revoke access for a device. Immediately configures hardware to block it.
   */
  async revokeAccess(user, deviceId) {
    try {
      await this.router.revokeAccess(user, deviceId);
      this.log.info('Hardware access revoked', { deviceId, backend: config.routerBackend });
    } catch (err) {
      this.log.error('Hardware revocation FAILED', { deviceId, error: err.message });
    }
  }

  // --------------------------------------------------------------------------
  //  ENTRY POINT
  // --------------------------------------------------------------------------

  async start() {
    this.log.info('=== DePIN Gateway Worker Starting ===', {
      version:  '1.0.0',
      gateway:  config.gatewayAddress,
      backend:  config.routerBackend,
      rpc:      config.rpcUrl,
    });

    // Step 1: Sync historical state from chain
    await this.syncHistoricalEvents();

    // Step 2: Start real-time event listeners
    this.startEventListeners();

    // Step 3: Start expiry poller (safety net)
    this.startExpiryPoller();

    this.log.info('Worker fully operational. Listening for events...');
  }
}

// ============================================================================
//                           GRACEFUL SHUTDOWN
// ============================================================================

const worker = new GatewayWorker();

process.on('SIGINT',  () => { worker.log.info('SIGINT received, shutting down'); process.exit(0); });
process.on('SIGTERM', () => { worker.log.info('SIGTERM received, shutting down'); process.exit(0); });
process.on('unhandledRejection', (reason) => {
  worker.log.error('Unhandled promise rejection', { reason: String(reason) });
});

worker.start().catch((err) => {
  console.error('Worker failed to start:', err);
  process.exit(1);
});