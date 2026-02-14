OHO Validator Manager (V32.1) — Technical Specification

1. System Overview

The OHO Validator Manager is a sovereign, on-chain validator lifecycle and governance contract designed for QBFT-based networks such as Hyperledger Besu.

It provides:

Deterministic validator set management

Custody-separated staking

Snapshot-based supermajority governance

Bonded proposal anti-spam mechanics

Slashing and pruning enforcement

Liveness-safe proposal lifecycle handling

The contract is designed to be:

Non-upgradeable

Adminless

Governance-controlled

Deterministic for consensus clients

2. Core Architecture
2.1 Custody Separation Model

Roles:

Staker

Supplies capital

Owns the stake economically

Can withdraw stake after exit

May fund multiple validators

Signer

Runs validator node

Participates in consensus

Votes in governance

Cannot withdraw funds

Invariant:

1 signer ↔ 1 staker
1 staker → N signers allowed


Stake ownership always resolves via:

stakerOf[signer]


Signer compromise does not risk funds.

2.2 Validator State Machine
None → Active → Leaving → None

None

Not a validator

Eligible to join

Active

In validator set

Votes in governance

Can propose

Can request exit

Leaving

Removed from validator set

In withdrawal delay

Cannot vote or propose

Transitions are strictly enforced.

3. Staking Mechanics
3.1 Fixed Stake Model

Each validator requires:

VALIDATOR_STAKE (fixed)


Properties:

No partial stake

No top-ups

No variable stake sizes

No compounding

Rationale:

Simplifies economics

Eliminates stake drift

Makes slashing deterministic

Improves auditability

3.2 Join Flow

Requirements:

Exact stake deposit

Signer unused

Signer cooldown elapsed

MAX_VALIDATORS not reached

Effects:

stakeBalance credited

stakerOf set

joinedAt recorded

Validator added to set

3.3 Exit Flow

Signer calls requestExit():

Immediate removal from validator set

State → Leaving

Withdrawal timer started

This guarantees fast validator set updates for QBFT.

3.4 Withdrawal Flow

Staker calls withdrawStake(signer):

Checks:

Caller is staker

Signer in Leaving

Delay elapsed

Effects:

Stake returned

Signer reset to None

Cooldown started

4. Governance Model
4.1 Snapshot Governance

At proposal creation:

snapshotValidatorCount = validatorList.length


Quorum:

votes * 10000 >= snapshotValidatorCount * GOVERNANCE_BPS


This prevents:

Validator churn attacks

Quorum griefing

Mid-vote manipulation

4.2 Proposal Types
Type 1 — Rule

Informational only

Off-chain enforced

Bond burns on expiry

Type 2 — Prune

Removes validator

No slashing

Used for liveness/performance

Type 3 — Slash

Applies fixed penalty

Forces exit

Burns portion of stake

4.3 Proposal Bonds

Purpose:

Prevent spam

Create economic friction

Incentivize serious proposals

Outcomes:

Success → returned
Failure → burned
Expiry → burned

4.4 Governance Restrictions

Only Active validators can:

Propose

Vote

Additional rules:

Must have joined before proposal start

Warmup delay before proposing

One vote per validator

5. Slashing Design

Slash amount:

VALIDATOR_STAKE * SLASH_BPS


Defensive invariant:

require(stakeBalance == VALIDATOR_STAKE)


Properties:

Single-shot slash

Always on full stake

No repeated partial slashes

Validator forced to exit

Burn is best-effort.

6. Liveness Protections
Expiry Handling

Anyone can finalize expired proposals.

Active Proposal Cap

Limits governance spam.

Serialized Removals

One removal proposal per target.

Defensive Counters

activeProposalCount protected from underflow.

7. Security Model
7.1 Reentrancy Safety

nonReentrant modifier

CEI pattern

7.2 Economic Safety

Fixed stake

Bonded governance

Cooldowns

7.3 Consensus Safety

Deterministic validator ordering

O(1) add/
