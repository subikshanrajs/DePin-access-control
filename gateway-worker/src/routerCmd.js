/**
 * RouterBackend — Hardware Interface Abstraction Layer
 *
 * This module translates high-level "grant access" / "revoke access" commands
 * into the appropriate hardware-specific calls:
 *
 *   - simulation : Logs to console (default, no hardware needed)
 *   - openwrt    : SSH into an OpenWrt router and manipulate the MAC filter list
 *                  via UCI (Unified Configuration Interface) or the LuCI REST API
 *   - radius     : POST to a FreeRADIUS management API to add/remove users
 *   - hostapd    : Write to a hostapd accept_macs file and send HUP signal
 *
 * To add a new backend: extend RouterBackend with a new case in grantAccess/revokeAccess.
 */

import { execSync } from 'child_process';

// ============================================================================
//                         BACKEND: SIMULATION
// ============================================================================

class SimulationBackend {
  constructor(log) {
    this.log = log;
    this.log.info('[SIM] Simulation router backend active — no hardware will be configured');
  }

  async grantAccess(user, deviceId, expiresAt) {
    const ttl = Math.max(0, expiresAt - Math.floor(Date.now() / 1000));
    this.log.info('[SIM] GRANT ACCESS', {
      deviceId: deviceId.slice(0, 10) + '...',
      wallet:   user.slice(0, 8) + '...',
      expiry:   new Date(expiresAt * 1000).toISOString(),
      ttlSeconds: ttl,
      simulatedCommand: `iptables -I FORWARD -m mac --mac-source ${deviceIdToMac(deviceId)} -j ACCEPT`,
    });
  }

  async revokeAccess(user, deviceId) {
    this.log.info('[SIM] REVOKE ACCESS', {
      deviceId: deviceId.slice(0, 10) + '...',
      simulatedCommand: `iptables -D FORWARD -m mac --mac-source ${deviceIdToMac(deviceId)} -j ACCEPT`,
    });
  }
}

// ============================================================================
//                         BACKEND: OPENWRT (SSH + UCI)
// ============================================================================

/**
 * OpenWrt backend: manages MAC-based access via the UCI network.wireless config.
 *
 * Requirements:
 *   - Router running OpenWrt with dropbear SSH
 *   - SSH key auth configured (or password auth via sshpass)
 *   - The wireless interface set to macfilter=allow mode
 *
 * Security note: The SSH password is pulled from env vars. Never hardcode.
 * For production, use SSH key pair auth and remove password support entirely.
 */
class OpenWrtBackend {
  constructor(log) {
    this.log  = log;
    this.host = process.env.OPENWRT_HOST;
    this.user = process.env.OPENWRT_USER || 'root';
    this.pass = process.env.OPENWRT_PASSWORD;
    this.iface = process.env.OPENWRT_INTERFACE || 'wlan0';

    if (!this.host) throw new Error('OPENWRT_HOST is required for openwrt backend');
  }

  _ssh(command) {
    // NOTE: In production use SSH key auth. sshpass is a dev convenience only.
    const sshCmd = this.pass
      ? `sshpass -p '${this.pass}' ssh -o StrictHostKeyChecking=no ${this.user}@${this.host} "${command}"`
      : `ssh ${this.user}@${this.host} "${command}"`;

    return execSync(sshCmd, { timeout: 10_000 }).toString().trim();
  }

  async grantAccess(user, deviceId, expiresAt) {
    // deviceId is a keccak256 hash — in a real deployment, you'd maintain
    // a mapping of deviceId -> MAC address in a separate database.
    // For this demo, we derive a deterministic-looking MAC from the hash.
    const mac = deviceIdToMac(deviceId);

    // Add MAC to the wireless interface allowlist via UCI
    const commands = [
      // Add the MAC to the maclist
      `uci add_list wireless.@wifi-iface[0].maclist='${mac}'`,
      // Set filter mode to whitelist (only listed MACs can connect)
      `uci set wireless.@wifi-iface[0].macfilter='allow'`,
      // Commit the change
      `uci commit wireless`,
      // Reload the wireless stack non-destructively
      `wifi reload`,
    ].join(' && ');

    this.log.info('[OpenWrt] Executing grant command', { mac, expiresAt });
    const output = this._ssh(commands);
    this.log.debug('[OpenWrt] SSH output', { output });
  }

  async revokeAccess(user, deviceId) {
    const mac = deviceIdToMac(deviceId);

    const commands = [
      // Remove the MAC from the allowlist
      // Note: uci del_list requires exact match
      `uci del_list wireless.@wifi-iface[0].maclist='${mac}'`,
      `uci commit wireless`,
      `wifi reload`,
    ].join(' && ');

    this.log.info('[OpenWrt] Executing revoke command', { mac });
    this._ssh(commands);
  }
}

// ============================================================================
//                     BACKEND: FREERADIUS (REST API)
// ============================================================================

/**
 * RADIUS backend: creates/deletes user accounts in FreeRADIUS via its
 * REST module. Works with any RADIUS-aware access point (enterprise-grade).
 *
 * Requirements:
 *   - FreeRADIUS with rlm_rest configured
 *   - REST API endpoint exposed (default: http://localhost:8080)
 *
 * The "username" sent to RADIUS is the deviceId itself (hex string).
 * The AP associates the device's MAC address with this RADIUS identity.
 */
class RadiusBackend {
  constructor(log) {
    this.log    = log;
    this.host   = process.env.RADIUS_HOST || '127.0.0.1';
    this.port   = process.env.RADIUS_PORT || '8080';
    this.secret = process.env.RADIUS_SECRET || 'testing123';
    this.baseUrl = `http://${this.host}:${this.port}`;
  }

  async _post(path, body) {
    const { default: fetch } = await import('node-fetch');
    const res = await fetch(`${this.baseUrl}${path}`, {
      method:  'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-RADIUS-Secret': this.secret,
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      throw new Error(`RADIUS API error: ${res.status} ${await res.text()}`);
    }
    return res.json();
  }

  async _delete(path) {
    const { default: fetch } = await import('node-fetch');
    const res = await fetch(`${this.baseUrl}${path}`, {
      method:  'DELETE',
      headers: { 'X-RADIUS-Secret': this.secret },
    });
    if (!res.ok && res.status !== 404) {
      throw new Error(`RADIUS API error: ${res.status}`);
    }
  }

  async grantAccess(user, deviceId, expiresAt) {
    const ttl = expiresAt - Math.floor(Date.now() / 1000);
    await this._post('/radcheck', {
      username:  deviceId,
      attribute: 'Cleartext-Password',
      op:        ':=',
      value:     deviceId, // password = deviceId for MAC-auth scenarios
    });
    // Set session timeout attribute
    await this._post('/radreply', {
      username:  deviceId,
      attribute: 'Session-Timeout',
      op:        ':=',
      value:     String(Math.max(1, ttl)),
    });
    this.log.info('[RADIUS] User created', { deviceId, ttl });
  }

  async revokeAccess(user, deviceId) {
    await this._delete(`/radcheck/${deviceId}`);
    await this._delete(`/radreply/${deviceId}`);
    this.log.info('[RADIUS] User deleted', { deviceId });
  }
}

// ============================================================================
//                           BACKEND FACTORY
// ============================================================================

export class RouterBackend {
  constructor(backendName, log) {
    switch (backendName) {
      case 'openwrt':
        this.impl = new OpenWrtBackend(log);
        break;
      case 'radius':
        this.impl = new RadiusBackend(log);
        break;
      case 'simulation':
      default:
        this.impl = new SimulationBackend(log);
        break;
    }
  }

  async grantAccess(user, deviceId, expiresAt) {
    return this.impl.grantAccess(user, deviceId, expiresAt);
  }

  async revokeAccess(user, deviceId) {
    return this.impl.revokeAccess(user, deviceId);
  }
}

// ============================================================================
//                           UTILITY
// ============================================================================

/**
 * Derive a deterministic MAC address from a bytes32 deviceId.
 * In production, maintain a real mapping (deviceId -> actual MAC address)
 * in a database, populated when the user registers their device.
 *
 * @param {string} deviceId - hex bytes32 string (0x...)
 * @returns {string} MAC address in XX:XX:XX:XX:XX:XX format
 */
function deviceIdToMac(deviceId) {
  // Take first 6 bytes of the deviceId hash as the MAC
  const hex = deviceId.replace('0x', '').slice(0, 12);
  return hex.match(/.{2}/g).join(':').toUpperCase();
}