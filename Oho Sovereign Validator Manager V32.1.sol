// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title Oho Sovereign Validator Manager (V32.1)
 * @notice Production-grade QBFT validator manager with:
 *         - Custody separation (staker funds, signer validates)
 *         - 1 staker → multiple signers allowed
 *         - Snapshot-based bonded governance
 *         - Anti-DoS proposal caps
 *         - Signer cooldowns
 *         - Liveness-safe execution paths
 *         - Best-effort burns
 *
 * V32.1 polish:
 *  - Slash invariant assertion added
 *  - Comments clarifying multi-staker design
 *  - Defensive activeProposalCount decrement documented
 *
 * ruleHash is informational and off-chain enforced.
 * Type-1 proposals are informational and free their slot on expiry.
 */
contract OhoValidatorManager {

    // --------------------------------------------------
    // Types
    // --------------------------------------------------

    enum ValidatorState { None, Active, Leaving }

    struct Proposal {
        uint8 propType; // 1=Rule,2=Prune,3=Slash
        address target;
        uint256 startTime;
        uint256 votes;
        uint256 snapshotValidatorCount;
        bool executed;
        bytes32 ruleHash; // informational
        address proposer;
    }

    // --------------------------------------------------
    // Constants
    // --------------------------------------------------

    uint256 public constant VALIDATOR_STAKE = 10_000_000 ether;

    uint256 public constant MIN_VALIDATORS = 4;
    uint256 public constant MAX_VALIDATORS = 50;

    uint256 public constant WITHDRAWAL_DELAY = 14 days;
    uint256 public constant SIGNER_COOLDOWN = 1 days;
    uint256 public constant GOVERNANCE_WARMUP = 1 days;

    uint256 public constant PROPOSAL_BOND = 100 ether;
    uint256 public constant PROPOSAL_EXPIRY = 7 days;
    uint256 public constant MAX_ACTIVE_PROPOSALS = 20;

    uint256 public constant GOVERNANCE_BPS = 9000;
    uint256 public constant SLASH_BPS = 50;

    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // --------------------------------------------------
    // Storage
    // --------------------------------------------------

    address[] public validatorList;
    mapping(address => uint256) public validatorIndex;

    mapping(address => ValidatorState) public validatorState;

    // signer => staker
    mapping(address => address) public stakerOf;

    // Stake is keyed by signer, but controlled by staker.
    // A staker may fund multiple validators by design.
    mapping(address => uint256) public stakeBalance;

    mapping(address => uint256) public withdrawalAvailableAt;
    mapping(address => uint256) public signerCooldown;
    mapping(address => uint256) public joinedAt;
    mapping(address => uint256) public totalSlashed;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => uint256) public proposalBond;
    mapping(address => uint256) public claimableBond;

    mapping(address => bool) public activeRemovalProposal;

    uint256 public proposalCount;
    uint256 public activeProposalCount;
    uint256 public totalBurned;

    bool private locked;

    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------

    modifier nonReentrant() {
        require(!locked,"REENTRANCY");
        locked = true;
        _;
        locked = false;
    }

    modifier onlyValidator() {
        require(
            validatorState[msg.sender] == ValidatorState.Active,
            "NOT_VALIDATOR"
        );
        _;
    }

    // --------------------------------------------------
    // Events
    // --------------------------------------------------

    event ValidatorJoined(address signer,address staker);
    event ValidatorLeft(address signer);
    event ValidatorSlashed(address signer,uint256 amt);

    event StakeWithdrawn(address signer,address staker,uint256 amt);
    event BondClaimed(address user,uint256 amt);

    event ProposalCreated(uint256 id,uint8 t,address target,address proposer);
    event ProposalExecuted(uint256 id,bool success,bytes32 ruleHash);
    event ProposalExpired(uint256 id);

    // --------------------------------------------------
    // Constructor
    // --------------------------------------------------

    constructor(
        address[] memory genesisSigners,
        address[] memory genesisStakers
    ) payable {
        uint256 n = genesisSigners.length;

        require(n >= MIN_VALIDATORS,"MIN");
        require(n <= MAX_VALIDATORS,"MAX");
        require(n == genesisStakers.length,"LEN");
        require(msg.value == n*VALIDATOR_STAKE,"STAKE");

        for(uint256 i; i<n; ++i){
            address s = genesisSigners[i];
            address st = genesisStakers[i];

            require(s!=address(0) && st!=address(0),"ZERO");
            require(validatorState[s]==ValidatorState.None,"DUP");

            validatorState[s]=ValidatorState.Active;
            stakerOf[s]=st;
            stakeBalance[s]=VALIDATOR_STAKE;
            joinedAt[s]=block.timestamp;

            _addValidator(s);
        }
    }

    // --------------------------------------------------
    // Join
    // --------------------------------------------------

    function joinRequest(address signer)
        external
        payable
        nonReentrant
    {
        require(msg.value==VALIDATOR_STAKE,"STAKE");
        require(signer!=address(0),"ZERO");

        require(
            signerCooldown[signer]<=block.timestamp,
            "COOLDOWN"
        );

        require(
            validatorState[signer]==ValidatorState.None,
            "USED"
        );

        require(
            validatorList.length<MAX_VALIDATORS,
            "FULL"
        );

        stakerOf[signer]=msg.sender;
        stakeBalance[signer]=msg.value;
        validatorState[signer]=ValidatorState.Active;
        joinedAt[signer]=block.timestamp;

        _addValidator(signer);

        emit ValidatorJoined(signer,msg.sender);
    }

    // --------------------------------------------------
    // Exit / Withdraw
    // --------------------------------------------------

    function requestExit() external onlyValidator {
        require(
            validatorList.length>MIN_VALIDATORS,
            "MIN"
        );

        address s=msg.sender;

        validatorState[s]=ValidatorState.Leaving;
        _removeValidator(s);

        withdrawalAvailableAt[s]=
            block.timestamp+WITHDRAWAL_DELAY;

        emit ValidatorLeft(s);
    }

    function withdrawStake(address signer)
        external
        nonReentrant
    {
        require(
            stakerOf[signer]==msg.sender,
            "NOT_STAKER"
        );

        require(
            validatorState[signer]==ValidatorState.Leaving,
            "NOT_LEAVING"
        );

        require(
            block.timestamp>=withdrawalAvailableAt[signer],
            "LOCKED"
        );

        uint256 amt=stakeBalance[signer];

        stakeBalance[signer]=0;
        validatorState[signer]=ValidatorState.None;
        withdrawalAvailableAt[signer]=0;

        signerCooldown[signer]=
            block.timestamp+SIGNER_COOLDOWN;

        delete stakerOf[signer];

        (bool ok,) =
            payable(msg.sender).call{value:amt}("");
        require(ok,"SEND");

        emit StakeWithdrawn(signer,msg.sender,amt);
    }

    // --------------------------------------------------
    // Governance
    // --------------------------------------------------

    function propose(
        uint8 t,
        address target,
        bytes32 ruleHash
    ) external payable onlyValidator returns(uint256){

        require(t>=1 && t<=3,"TYPE");

        require(
            block.timestamp>=
            joinedAt[msg.sender]+GOVERNANCE_WARMUP,
            "WARMUP"
        );

        require(msg.value==PROPOSAL_BOND,"BOND");

        require(
            activeProposalCount<MAX_ACTIVE_PROPOSALS,
            "CAP"
        );

        if(t>=2){
            require(target!=address(0),"ZERO");
            require(
                validatorState[target]==ValidatorState.Active,
                "TARGET"
            );
            require(
                !activeRemovalProposal[target],
                "PENDING"
            );

            activeRemovalProposal[target]=true;
        }

        proposalCount++;
        activeProposalCount++;

        proposals[proposalCount]=Proposal({
            propType:t,
            target:target,
            startTime:block.timestamp,
            votes:0,
            snapshotValidatorCount:validatorList.length,
            executed:false,
            ruleHash:ruleHash,
            proposer:msg.sender
        });

        proposalBond[proposalCount]=msg.value;

        emit ProposalCreated(
            proposalCount,t,target,msg.sender
        );

        return proposalCount;
    }

    function vote(uint256 id) external onlyValidator {
        Proposal storage p=proposals[id];

        require(!p.executed,"DONE");
        require(
            block.timestamp<=
            p.startTime+PROPOSAL_EXPIRY,
            "EXP"
        );

        require(
            joinedAt[msg.sender]<=p.startTime,
            "NEW"
        );

        require(
            !hasVoted[id][msg.sender],
            "VOTED"
        );

        hasVoted[id][msg.sender]=true;
        p.votes++;

        if(
            p.votes*10000 >=
            p.snapshotValidatorCount*GOVERNANCE_BPS
        ){
            _executeProposal(id);
        }
    }

    function finalizeExpired(uint256 id) external {
        Proposal storage p=proposals[id];

        require(!p.executed,"DONE");
        require(
            block.timestamp>
            p.startTime+PROPOSAL_EXPIRY,
            "LIVE"
        );

        p.executed=true;

        uint256 bond=proposalBond[id];
        if(bond>0){
            proposalBond[id]=0;
            _burn(bond);
        }

        if(p.propType>=2)
            activeRemovalProposal[p.target]=false;

        // Defensive decrement to avoid underflow
        // in multi-path execution ordering.
        if(activeProposalCount>0)
            activeProposalCount--;

        emit ProposalExpired(id);
    }

    function claimBond() external nonReentrant {
        uint256 amt=claimableBond[msg.sender];
        require(amt>0,"NONE");

        claimableBond[msg.sender]=0;

        (bool ok,) =
            payable(msg.sender).call{value:amt}("");
        require(ok,"SEND");

        emit BondClaimed(msg.sender,amt);
    }

    // --------------------------------------------------
    // Execution
    // --------------------------------------------------

    function _executeProposal(uint256 id) internal {
        Proposal storage p=proposals[id];
        if(p.executed) return;

        p.executed=true;

        bool success=true;

        if(p.propType==2)
            success=_tryPrune(p.target);
        else if(p.propType==3)
            success=_trySlash(p.target);

        uint256 bond=proposalBond[id];
        if(bond>0){
            proposalBond[id]=0;

            if(success)
                claimableBond[p.proposer]+=bond;
            else
                _burn(bond);
        }

        if(p.propType>=2)
            activeRemovalProposal[p.target]=false;

        // Defensive decrement to avoid underflow
        if(activeProposalCount>0)
            activeProposalCount--;

        emit ProposalExecuted(
            id,success,p.ruleHash
        );
    }

    // --------------------------------------------------
    // Enforcement
    // --------------------------------------------------

    function _trySlash(address v)
        internal
        returns(bool)
    {
        if(
            validatorList.length<=MIN_VALIDATORS ||
            validatorState[v]!=ValidatorState.Active
        ) return false;

        // Explicit invariant lock
        require(
            stakeBalance[v]==VALIDATOR_STAKE,
            "STAKE_CORRUPT"
        );

        uint256 amt=
            (VALIDATOR_STAKE*SLASH_BPS)/10000;

        totalSlashed[v]+=amt;
        stakeBalance[v]-=amt;

        validatorState[v]=ValidatorState.Leaving;
        _removeValidator(v);

        withdrawalAvailableAt[v]=
            block.timestamp+WITHDRAWAL_DELAY;

        _burn(amt);

        emit ValidatorSlashed(v,amt);
        emit ValidatorLeft(v);

        return true;
    }

    function _tryPrune(address v)
        internal
        returns(bool)
    {
        if(
            validatorList.length<=MIN_VALIDATORS ||
            validatorState[v]!=ValidatorState.Active
        ) return false;

        validatorState[v]=ValidatorState.Leaving;
        _removeValidator(v);

        withdrawalAvailableAt[v]=
            block.timestamp+WITHDRAWAL_DELAY;

        emit ValidatorLeft(v);
        return true;
    }

    // --------------------------------------------------
    // Burn (best-effort by design)
    // --------------------------------------------------

    function _burn(uint256 amt) internal {
        (bool ok,) =
            BURN_ADDRESS.call{value:amt}("");
        if(ok) totalBurned+=amt;
    }

    // --------------------------------------------------
    // Validator list helpers
    // --------------------------------------------------

    function _addValidator(address v) internal {
        validatorIndex[v]=validatorList.length;
        validatorList.push(v);
    }

    function _removeValidator(address v) internal {
        uint256 i=validatorIndex[v];
        uint256 l=validatorList.length-1;

        if(i!=l){
            address last=validatorList[l];
            validatorList[i]=last;
            validatorIndex[last]=i;
        }

        validatorList.pop();
        delete validatorIndex[v];
    }

    function getValidators()
        external
        view
        returns(address[] memory)
    {
        return validatorList;
    }
}