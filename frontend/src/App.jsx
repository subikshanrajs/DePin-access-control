// src/App.jsx
// DePIN Access Protocol — Main Frontend Application

import { useState, useEffect } from 'react';
import { WagmiProvider, useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from 'wagmi';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { arbitrumSepolia } from 'wagmi/chains';
import { wagmiConfig } from './lib/config.js';
import {
  useAllTiers,
  useSessionStatus,
  usePurchaseAccess,
  toDeviceIdBytes32,
  formatCountdown,
} from './hooks/useAccessGateway.js';

const queryClient = new QueryClient();

// ============================================================================
//                          ROOT PROVIDERS
// ============================================================================

export default function App() {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <AppContent />
      </QueryClientProvider>
    </WagmiProvider>
  );
}

// ============================================================================
//                          MAIN APP CONTENT
// ============================================================================

function AppContent() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  // Default device ID = user's wallet address (one device per wallet by default)
  // In a real deployment, user would paste their MAC address or scan a QR code
  const [deviceId, setDeviceId] = useState('');
  const [selectedTierId, setSelectedTierId] = useState(0);
  const [showDeviceInput, setShowDeviceInput] = useState(false);

  const isCorrectChain = chainId === arbitrumSepolia.id;

  return (
    <div className="app">
      <Header address={address} isConnected={isConnected} />

      <main className="main">
        {!isConnected ? (
          <ConnectWallet />
        ) : !isCorrectChain ? (
          <WrongNetwork onSwitch={() => switchChain({ chainId: arbitrumSepolia.id })} />
        ) : (
          <Dashboard
            address={address}
            deviceId={deviceId || address}
            selectedTierId={selectedTierId}
            onSelectTier={setSelectedTierId}
            showDeviceInput={showDeviceInput}
            onToggleDeviceInput={() => setShowDeviceInput(v => !v)}
            onDeviceIdChange={setDeviceId}
          />
        )}
      </main>

      <footer className="footer">
        <p>DePIN Access Protocol · Arbitrum · <a href="#" className="link">View on Arbiscan</a></p>
      </footer>
    </div>
  );
}

// ============================================================================
//                          HEADER
// ============================================================================

function Header({ address, isConnected }) {
  const { disconnect } = useDisconnect();

  return (
    <header className="header">
      <div className="header-brand">
        <div className="logo">
          <svg width="28" height="28" viewBox="0 0 28 28" fill="none">
            <rect width="28" height="28" rx="6" fill="#2D6AFF"/>
            <path d="M14 5L20 9.5V14L14 18.5L8 14V9.5L14 5Z" stroke="white" strokeWidth="1.5" fill="none"/>
            <circle cx="14" cy="14" r="3" fill="white"/>
            <path d="M14 18.5V23" stroke="white" strokeWidth="1.5" strokeLinecap="round"/>
          </svg>
        </div>
        <span className="brand-name">NetPass</span>
        <span className="brand-sub">DePIN Protocol</span>
      </div>
      {isConnected && (
        <div className="header-wallet">
          <div className="wallet-address">
            <div className="wallet-dot" />
            {address?.slice(0, 6)}…{address?.slice(-4)}
          </div>
          <button className="btn-ghost" onClick={() => disconnect()}>Disconnect</button>
        </div>
      )}
    </header>
  );
}

// ============================================================================
//                          CONNECT WALLET
// ============================================================================

function ConnectWallet() {
  const { connectors, connect, isPending } = useConnect();

  return (
    <div className="connect-screen">
      <div className="connect-card">
        <div className="connect-icon">
          <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
            <rect width="48" height="48" rx="12" fill="#EEF2FF"/>
            <path d="M24 10L34 16V24L24 30L14 24V16L24 10Z" stroke="#2D6AFF" strokeWidth="2" fill="none"/>
            <circle cx="24" cy="24" r="5" fill="#2D6AFF"/>
            <path d="M24 30V38" stroke="#2D6AFF" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
        <h1 className="connect-title">Decentralized Wi-Fi Access</h1>
        <p className="connect-desc">
          Pay ETH on Arbitrum. Get instant, time-boxed network access.<br />
          No accounts. No passwords. Just your wallet.
        </p>
        <div className="connector-list">
          {connectors.map((connector) => (
            <button
              key={connector.uid}
              className="connector-btn"
              onClick={() => connect({ connector })}
              disabled={isPending}
            >
              {connector.name}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ============================================================================
//                          WRONG NETWORK
// ============================================================================

function WrongNetwork({ onSwitch }) {
  return (
    <div className="connect-screen">
      <div className="connect-card">
        <div className="error-icon">⚠️</div>
        <h2 className="connect-title">Wrong Network</h2>
        <p className="connect-desc">Please switch to Arbitrum Sepolia to use this app.</p>
        <button className="btn-primary" onClick={onSwitch}>Switch Network</button>
      </div>
    </div>
  );
}

// ============================================================================
//                          DASHBOARD
// ============================================================================

function Dashboard({ address, deviceId, selectedTierId, onSelectTier, showDeviceInput, onToggleDeviceInput, onDeviceIdChange }) {
  const { tiers, isLoading: tiersLoading } = useAllTiers();
  const { isActive, expiresAt, remainingSeconds, refetch } = useSessionStatus(address, deviceId);
  const { purchase, extend, isPending, isConfirming, isSuccess, error, reset, txHash } =
    usePurchaseAccess();

  const [countdown, setCountdown] = useState(remainingSeconds);

  // Live countdown timer
  useEffect(() => {
    setCountdown(remainingSeconds);
    if (remainingSeconds <= 0) return;
    const interval = setInterval(() => {
      setCountdown(prev => Math.max(0, prev - 1));
    }, 1000);
    return () => clearInterval(interval);
  }, [remainingSeconds]);

  // Refetch after successful purchase
  useEffect(() => {
    if (isSuccess) {
      setTimeout(refetch, 3000);
    }
  }, [isSuccess, refetch]);

  const selectedTier = tiers[selectedTierId];

  const handlePurchase = async () => {
    if (!selectedTier) return;
    reset();
    if (isActive) {
      await extend(deviceId, selectedTier.id, selectedTier.priceWei);
    } else {
      await purchase(deviceId, selectedTier.id, selectedTier.priceWei);
    }
  };

  return (
    <div className="dashboard">
      {/* Left column: Session status */}
      <div className="card session-card">
        <div className="card-header">
          <h2 className="card-title">Your Session</h2>
          <div className={`status-badge ${isActive ? 'status-active' : 'status-inactive'}`}>
            {isActive ? '● Active' : '○ Inactive'}
          </div>
        </div>

        {isActive ? (
          <div className="session-active">
            <div className="countdown">{formatCountdown(countdown)}</div>
            <div className="expiry-label">
              Expires {expiresAt?.toLocaleTimeString()} · {expiresAt?.toLocaleDateString()}
            </div>
            <div className="progress-track">
              <div
                className="progress-fill"
                style={{
                  width: `${Math.min(100, (countdown / (selectedTier?.durationSeconds || 3600)) * 100)}%`
                }}
              />
            </div>
          </div>
        ) : (
          <div className="session-inactive">
            <div className="inactive-icon">🔒</div>
            <p className="inactive-text">No active session. Purchase access below to connect.</p>
          </div>
        )}

        {/* Device ID section */}
        <div className="device-section">
          <div className="device-row">
            <span className="device-label">Device ID</span>
            <button className="btn-ghost-sm" onClick={onToggleDeviceInput}>
              {showDeviceInput ? 'Use wallet address' : 'Custom device'}
            </button>
          </div>
          {showDeviceInput ? (
            <input
              type="text"
              className="device-input"
              placeholder="Enter device MAC or identifier"
              onChange={e => onDeviceIdChange(e.target.value)}
            />
          ) : (
            <div className="device-value">
              {deviceId?.slice(0, 8)}…{deviceId?.slice(-6)}
            </div>
          )}
        </div>
      </div>

      {/* Right column: Tier selection + purchase */}
      <div className="card purchase-card">
        <div className="card-header">
          <h2 className="card-title">
            {isActive ? 'Extend Access' : 'Purchase Access'}
          </h2>
        </div>

        {tiersLoading ? (
          <div className="loading-tiers">Loading tiers…</div>
        ) : (
          <div className="tier-grid">
            {tiers.map((tier, i) => (
              <button
                key={tier.id}
                className={`tier-card ${selectedTierId === i ? 'tier-selected' : ''}`}
                onClick={() => onSelectTier(i)}
              >
                <div className="tier-duration">{tier.durationLabel}</div>
                <div className="tier-price">{parseFloat(tier.priceEth).toFixed(4)} ETH</div>
                <div className="tier-label">{tier.label}</div>
              </button>
            ))}
          </div>
        )}

        {selectedTier && (
          <div className="purchase-summary">
            <div className="summary-row">
              <span>Duration</span>
              <span>{selectedTier.durationLabel}</span>
            </div>
            <div className="summary-row">
              <span>Price</span>
              <span className="price-highlight">{parseFloat(selectedTier.priceEth).toFixed(4)} ETH</span>
            </div>
          </div>
        )}

        {/* Transaction state */}
        {isPending && (
          <div className="tx-state tx-pending">⏳ Confirm in wallet…</div>
        )}
        {isConfirming && (
          <div className="tx-state tx-confirming">
            ⛓️ Confirming…
            {txHash && (
              <a
                href={`https://sepolia.arbiscan.io/tx/${txHash}`}
                target="_blank"
                rel="noreferrer"
                className="tx-link"
              >
                View tx
              </a>
            )}
          </div>
        )}
        {isSuccess && (
          <div className="tx-state tx-success">✅ Access granted! Your session is now active.</div>
        )}
        {error && (
          <div className="tx-state tx-error">
            ❌ {parseContractError(error)}
          </div>
        )}

        <button
          className="btn-primary btn-purchase"
          onClick={handlePurchase}
          disabled={isPending || isConfirming || !selectedTier}
        >
          {isPending       ? 'Confirm in wallet…'
           : isConfirming  ? 'Waiting for confirmation…'
           : isActive      ? `Extend for ${selectedTier?.durationLabel ?? '…'}`
           : `Buy ${selectedTier?.durationLabel ?? '…'} — ${selectedTier ? parseFloat(selectedTier.priceEth).toFixed(4) : '…'} ETH`}
        </button>

        <p className="purchase-note">
          Payments are non-refundable. Access is granted automatically on-chain.
          Powered by Arbitrum.
        </p>
      </div>
    </div>
  );
}

// ============================================================================
//                          UTILITY
// ============================================================================

function parseContractError(err) {
  const msg = err?.shortMessage || err?.message || 'Transaction failed';
  if (msg.includes('InsufficientPayment')) return 'Insufficient ETH sent';
  if (msg.includes('SessionAlreadyActive'))  return 'Session already active — use Extend';
  if (msg.includes('TierInactive'))         return 'This tier is no longer available';
  if (msg.includes('ContractPaused'))       return 'Protocol is paused for maintenance';
  if (msg.includes('User rejected'))        return 'Transaction rejected';
  return msg.slice(0, 80);
}
