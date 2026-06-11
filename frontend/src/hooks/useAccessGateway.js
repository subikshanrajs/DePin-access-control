// src/hooks/useAccessGateway.js
// React hooks for interacting with the AccessGateway contract

import { useReadContract, useWriteContract, useWaitForTransactionReceipt, useChainId } from 'wagmi';
import { keccak256, toHex, parseEther, formatEther } from 'viem';
import { useMemo, useState } from 'react';
import { GATEWAY_ABI, CONTRACTS } from '../lib/config.js';

// ============================================================================
//                       HOOK: useGatewayAddress
// ============================================================================

export function useGatewayAddress() {
  const chainId = useChainId();
  return CONTRACTS[chainId]?.AccessGateway || null;
}

// ============================================================================
//                       HOOK: useAllTiers
// ============================================================================

/**
 * Fetches all pricing tiers from the contract.
 * Returns formatted tier objects with human-readable duration strings.
 */
export function useAllTiers() {
  const gatewayAddress = useGatewayAddress();

  const { data, isLoading, error, refetch } = useReadContract({
    address:      gatewayAddress,
    abi:          GATEWAY_ABI,
    functionName: 'getAllTiers',
    query: { enabled: !!gatewayAddress },
  });

  const tiers = useMemo(() => {
    if (!data) return [];
    return data
      .map((tier, index) => ({
        id:              index,
        label:           tier.label,
        durationSeconds: Number(tier.durationSeconds),
        priceWei:        tier.priceWei,
        priceEth:        formatEther(tier.priceWei),
        active:          tier.active,
        durationLabel:   formatDuration(Number(tier.durationSeconds)),
      }))
      .filter(t => t.active);
  }, [data]);

  return { tiers, isLoading, error, refetch };
}

// ============================================================================
//                       HOOK: useSessionStatus
// ============================================================================

/**
 * Checks current session status for a user+device pair.
 * Polls every 15 seconds to keep the UI up to date.
 */
export function useSessionStatus(userAddress, deviceId) {
  const gatewayAddress = useGatewayAddress();
  const deviceIdBytes32 = deviceId ? toDeviceIdBytes32(deviceId) : null;

  const { data, isLoading, error, refetch } = useReadContract({
    address:      gatewayAddress,
    abi:          GATEWAY_ABI,
    functionName: 'checkAccess',
    args:         [userAddress, deviceIdBytes32],
    query: {
      enabled:           !!gatewayAddress && !!userAddress && !!deviceIdBytes32,
      refetchInterval:   15_000,
    },
  });

  const { data: remainingData } = useReadContract({
    address:      gatewayAddress,
    abi:          GATEWAY_ABI,
    functionName: 'remainingTime',
    args:         [userAddress, deviceIdBytes32],
    query: {
      enabled:         !!gatewayAddress && !!userAddress && !!deviceIdBytes32 && data?.[0],
      refetchInterval: 15_000,
    },
  });

  return {
    isActive:        data?.[0] ?? false,
    expiresAt:       data?.[1] ? new Date(Number(data[1]) * 1000) : null,
    remainingSeconds: remainingData ? Number(remainingData) : 0,
    isLoading,
    error,
    refetch,
  };
}

// ============================================================================
//                       HOOK: usePurchaseAccess
// ============================================================================

/**
 * Handles the full purchase flow:
 *   1. Submit transaction
 *   2. Wait for confirmation
 *   3. Return status for UI feedback
 */
export function usePurchaseAccess() {
  const gatewayAddress = useGatewayAddress();
  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess, error: receiptError } =
    useWaitForTransactionReceipt({ hash });

  const purchase = async (deviceId, tierId, priceWei) => {
    if (!gatewayAddress) throw new Error('Gateway address not found for this network');

    const deviceIdBytes32 = toDeviceIdBytes32(deviceId);

    writeContract({
      address:      gatewayAddress,
      abi:          GATEWAY_ABI,
      functionName: 'purchaseAccess',
      args:         [deviceIdBytes32, BigInt(tierId)],
      value:        priceWei,
    });
  };

  const extend = async (deviceId, tierId, priceWei) => {
    if (!gatewayAddress) throw new Error('Gateway address not found for this network');

    const deviceIdBytes32 = toDeviceIdBytes32(deviceId);

    writeContract({
      address:      gatewayAddress,
      abi:          GATEWAY_ABI,
      functionName: 'extendAccess',
      args:         [deviceIdBytes32, BigInt(tierId)],
      value:        priceWei,
    });
  };

  return {
    purchase,
    extend,
    txHash:       hash,
    isPending,
    isConfirming,
    isSuccess,
    error:        writeError || receiptError,
    reset,
  };
}

// ============================================================================
//                           UTILITY
// ============================================================================

/**
 * Convert a device identifier string (MAC address, UUID, etc.) to bytes32.
 * The IoT worker uses the same function to map deviceId -> hardware.
 */
export function toDeviceIdBytes32(deviceId) {
  return keccak256(toHex(deviceId));
}

/**
 * Format a duration in seconds to a human-readable string
 */
export function formatDuration(seconds) {
  if (seconds < 3600)   return `${Math.round(seconds / 60)} min`;
  if (seconds < 86400)  return `${Math.round(seconds / 3600)} hr`;
  if (seconds < 604800) return `${Math.round(seconds / 86400)} day${seconds >= 172800 ? 's' : ''}`;
  return `${Math.round(seconds / 604800)} week${seconds >= 1209600 ? 's' : ''}`;
}

/**
 * Format remaining time as a countdown string
 */
export function formatCountdown(seconds) {
  if (seconds <= 0) return 'Expired';
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}h ${m}m remaining`;
  if (m > 0) return `${m}m ${s}s remaining`;
  return `${s}s remaining`;
}