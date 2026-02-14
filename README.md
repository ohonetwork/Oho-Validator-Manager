***

# OHO Sovereign Validator Manager (V32.1)

The **OHO Sovereign Validator Manager** is a decentralized, production-grade smart contract designed to manage the validator set for the OHO Network running on **Hyperledger Besu QBFT** consensus. It implements a "Sovereign" governance model, removing central administrative control in favor of algorithmic enforcement and validator-led consensus.

## 🚀 Key Features

### 1. Custody Separation (Stash & Controller Model)
V32.1 implements a high-security custody model that separates capital from consensus power:
*   **Staker (Cold Wallet):** Holds the 10,000,000 OHO stake. This address can be a hardware wallet (Ledger/Trezor). It is the only address authorized to withdraw funds.
*   **Signer (Hot Node):** The key residing on the Besu server. It has the power to sign blocks and vote in governance but **zero power** to move or withdraw the staked funds.
*   **Multi-Signer Support:** A single staker address can fund and control multiple validator nodes.

### 2. Permissionless Automated Membership
The contract enables a self-service network growth model:
*   **Automatic Joins:** Any user with exactly 10,000,000 OHO can call `joinRequest(signer)` to immediately add a new node to the consensus set.
*   **Capacity Management:** Hard-coded limit of **50 validators** to ensure optimal P2P performance at a 2-second block time.
*   **Exit Lifecycle:** Validators can call `requestExit()` to leave the set. A **14-day withdrawal delay** is enforced to ensure "skin in the game" and prevent flash-manipulation of the validator set.

### 3. "Fortress" Governance (90% Quorum)
Governance is designed to be extremely conservative, ensuring the chain rules only change under near-unanimous agreement:
*   **90% Threshold:** Rule changes (Type-1) require 90% of the active validator set to vote "Yes."
*   **Anti-Hijack Snapshots:** A validator's voting power is determined at the moment a proposal is created. This prevents "Flash Joins" where an attacker adds nodes mid-vote to hijack the results.
*   **Governance Warmup:** New validators must wait **1 day** before they are allowed to propose rule changes.

### 4. Liveness & Slashing
The contract provides tools to maintain the 2-second block time heartbeat:
*   **Emergency Pruning:** A 90% majority can remove a "dead" or non-responsive node to prevent a governance deadlock.
*   **Punitive Slashing:** Malicious actors can be slashed by **0.5% (50,000 OHO)**.
*   **Honest Burn Accounting:** All slashed funds are sent to the `0x...dEaD` address, and the contract maintains a transparent `totalBurned` counter for supply auditing.

### 5. Technical Specification & Performance
*   **Besu QBFT Native:** Fully compatible with the `validatorcontractaddress` parameter in Besu 24.x and 25.x.
*   **$O(1)$ Efficiency:** The `getValidators()` function is optimized for constant-time lookup, ensuring consensus checks do not add latency to the 2-second block production.
*   **EIP-1559 Ready:** Fully compatible with the London hard fork and base-fee burning.

## 📊 Governance Summary

| Action | Required Threshold | Execution Type |
| :--- | :--- | :--- |
| **Join Network** | 10,000,000 OHO | Automatic |
| **Leave Network** | Self-Triggered | 14-Day Delay |
| **Rule Change** | 90% Unanimity | 7-Day Voting |
| **Prune/Slash Node** | 90% Unanimity | Immediate |

## 🛠 Deployment Details
*   **Solidity Version:** 0.8.19
*   **EVM Version:** London
*   **Compiler Optimization:** Enabled (200 Runs)
*   **Consensus Engine:** QBFT (Quorum Byzantine Fault Tolerance)

---

### Security Disclaimer
*This contract governs the core consensus of the OHO Network. Changes to the logic via Type-1 proposals should be preceded by a minimum 7-day community review period.*

***
