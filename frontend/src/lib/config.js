// src/lib/config.js
// Wagmi + Viem configuration for the DePIN frontend

import { createConfig, http } from 'wagmi';
import { arbitrum, arbitrumSepolia } from 'wagmi/chains';
import { metaMask, coinbaseWallet, walletConnect } from '@wagmi/connectors';

// ============================================================================
//                        CONTRACT ADDRESSES
// ============================================================================
// These are populated from the deployment script output (deployments/latest.json).
// In a real app, load these from an env variable or a config JSON.

export const CONTRACTS = {
  // Arbitrum Sepolia (testnet)
  421614: {
    AccessGateway:   import.meta.env.VITE_GATEWAY_ADDRESS_TESTNET  || '0x0000000000000000000000000000000000000001',
    SessionRegistry: import.meta.env.VITE_REGISTRY_ADDRESS_TESTNET || '0x0000000000000000000000000000000000000002',
  },
  // Arbitrum One (mainnet)
  42161: {
    AccessGateway:   import.meta.env.VITE_GATEWAY_ADDRESS_MAINNET  || '0x0000000000000000000000000000000000000001',
    SessionRegistry: import.meta.env.VITE_REGISTRY_ADDRESS_MAINNET || '0x0000000000000000000000000000000000000002',
  },
};

// ============================================================================
//                           WAGMI CONFIG
// ============================================================================

export const wagmiConfig = createConfig({
  chains: [arbitrumSepolia, arbitrum],
  connectors: [
    metaMask(),
    coinbaseWallet({ appName: 'DePIN Access Protocol' }),
    walletConnect({ projectId: import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || '' }),
  ],
  transports: {
    [arbitrumSepolia.id]: http(),
    [arbitrum.id]:        http(),
  },
});

// ============================================================================
//                         CONTRACT ABI
// ============================================================================

export const GATEWAY_ABI = [
  // ---- Read Functions --------------------------------------------------------
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
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getAllTiers',
    stateMutability: 'view',
    inputs: [],
    outputs: [{
      name: '',
      type: 'tuple[]',
      components: [
        { name: 'durationSeconds', type: 'uint256' },
        { name: 'priceWei',        type: 'uint256' },
        { name: 'active',          type: 'bool'    },
        { name: 'label',           type: 'string'  },
      ],
    }],
  },
  {
    type: 'function',
    name: 'tierCount',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'totalRevenue',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  // ---- Write Functions -------------------------------------------------------
  {
    type: 'function',
    name: 'purchaseAccess',
    stateMutability: 'payable',
    inputs: [
      { name: 'deviceId', type: 'bytes32' },
      { name: 'tierId',   type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'extendAccess',
    stateMutability: 'payable',
    inputs: [
      { name: 'deviceId', type: 'bytes32' },
      { name: 'tierId',   type: 'uint256' },
    ],
    outputs: [],
  },
  // ---- Events ---------------------------------------------------------------
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
  // ---- Errors ---------------------------------------------------------------
  { type: 'error', name: 'InsufficientPayment',   inputs: [{ type: 'uint256' }, { type: 'uint256' }] },
  { type: 'error', name: 'InvalidTier',           inputs: [{ type: 'uint256' }] },
  { type: 'error', name: 'TierInactive',          inputs: [{ type: 'uint256' }] },
  { type: 'error', name: 'SessionAlreadyActive',  inputs: [{ type: 'address' }, { type: 'bytes32' }, { type: 'uint256' }] },
  { type: 'error', name: 'SessionNotFound',       inputs: [{ type: 'address' }, { type: 'bytes32' }] },
  { type: 'error', name: 'ContractPaused',        inputs: [] },
];