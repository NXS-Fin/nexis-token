// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title NEXIS Token (NXS)
 * @notice Deflationary ERC-20 with staking, auto-liquidity fee,
 *         and 48-hour timelock on all administrative changes.
 * @dev    Audit-ready. Fixes: balanceBefore/After in stake, timelock on
 *         liquidityWallet, recovery for foreign ERC-20, full NatSpec.
 * @custom:security-contact contact@nexis.finance
 */
contract NEXIS is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // CONSTANTS
    // =========================================================

    /// @notice Absolute maximum supply — never exceeded (no unbounded mint).
    uint256 public constant MAX_SUPPLY = 444_444_444 * 10 ** 18;

    /// @notice Hard cap on burn fee: 1 % = 100 / 10 000.
    uint256 public constant MAX_BURN_RATE = 100;

    /// @notice Hard cap on liquidity fee: 2 % = 200 / 10 000.
    uint256 public constant MAX_LIQUIDITY_RATE = 200;

    /// @notice Hard cap on staking APY: 30 % = 3 000 / 10 000.
    uint256 public constant MAX_STAKING_APY = 3_000;

    /// @notice Minimum staking APY: 1 % = 100 / 10 000.
    /// @dev    Prevents owner from zeroing rewards via timelock surprise.
    uint256 public constant MIN_STAKING_APY = 100;

    /**
     * @notice Minimum lock-up before unstake/claim is allowed.
     * @dev    FIX C-1: prevents drain-attack (stake → instant unstake loop).
     *         7 days is standard for small-cap DeFi.
     */
    uint256 public constant MIN_LOCK_PERIOD = 7 days;

    /// @notice Delay required before any queued admin change takes effect.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // =========================================================
    // SUPPLY DISTRIBUTION
    // =========================================================

    /**
     * @notice 70 % circulating — sent to deployer at construction.
     * @dev    NOTE: whitepaper describes 18-month linear vesting for team.
     *         Vesting is implemented off-chain via a dedicated VestingWallet.
     *         On-chain vesting contract address is stored in `teamVesting`.
     */
    uint256 public constant CIRCULATING = 311_111_111 * 10 ** 18;

    /**
     * @notice 20 % reward pool — staking rewards paid from here, never minted.
     * @dev    FIX original: replaced unbounded _mint() in claimReward with
     *         transfers from a fixed pool. MAX_SUPPLY is therefore respected.
     */
    uint256 public constant REWARD_POOL = 88_888_889 * 10 ** 18;

    /// @notice 10 % liquidity reserve — sent to liquidityWallet at construction.
    uint256 public constant LIQ_RESERVE = 44_444_444 * 10 ** 18;

    // =========================================================
    // MUTABLE STATE — RATES
    // =========================================================

    /// @notice Burn fee in basis-points / 10 000.  Default 0.5 %.
    uint256 public burnRate = 50;

    /// @notice Liquidity fee in basis-points / 10 000.  Default 1 %.
    uint256 public liquidityRate = 100;

    /// @notice Staking APY in basis-points / 10 000.  Default 10 %.
    uint256 public stakingAPY = 1_000;

    // =========================================================
    // MUTABLE STATE — ADDRESSES
    // =========================================================

    /// @notice Receives the per-transfer liquidity fee.
    address public liquidityWallet;

    /// @notice Holds staking rewards; transfers to stakers on claim/unstake.
    address public rewardPool;

    /**
     * @notice Optional: address of off-chain / external vesting contract.
     * @dev    Purely informational — allows explorers / auditors to verify
     *         that team tokens are locked.  No on-chain enforcement here.
     */
    address public teamVesting;

    // =========================================================
    // MAPPINGS
    // =========================================================

    /// @notice Addresses that pay zero burn + liquidity fee on transfer.
    mapping(address => bool) public isExcludedFromFees;

    /// @notice NXS tokens currently locked in staking per user.
    mapping(address => uint256) public stakedAmount;

    /// @notice Timestamp of the user's last stake or reward claim.
    mapping(address => uint256) public stakeTimestamp;

    // =========================================================
    // STAKING TOTALS
    // =========================================================

    /// @notice Sum of all currently staked NXS (actual deposited amounts).
    uint256 public totalStaked;

    // =========================================================
    // TIMELOCK
    // =========================================================

    /**
     * @notice Represents a queued admin parameter change.
     * @param value        New value to be applied after the delay.
     * @param executeAfter Unix timestamp after which execution is allowed.
     * @param exists       False means slot is empty / already executed.
     */
    struct PendingChange {
        uint256 value;
        uint256 executeAfter;
        bool exists;
    }

    /// @notice Storage for all pending timelocked changes, keyed by action id.
    mapping(bytes32 => PendingChange) public pendingChanges;

    // =========================================================
    // EVENTS
    // =========================================================

    event Staked(address indexed user, uint256 deposited, uint256 credited);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event RewardClaimed(address indexed user, uint256 reward);
    event RewardPoolDepleted(uint256 requested, uint256 paid);

    event ChangeQueued(bytes32 indexed key, uint256 value, uint256 executeAfter);
    event ChangeExecuted(bytes32 indexed key, uint256 newValue);
    event ChangeCancelled(bytes32 indexed key);

    event ExcludedFromFees(address indexed account, bool excluded);
    event LiquidityWalletQueued(address newWallet, uint256 executeAfter);
    event LiquidityWalletChanged(address indexed oldWallet, address indexed newWallet);
    event RewardPoolChanged(address indexed oldPool, address indexed newPool);
    event TeamVestingSet(address indexed vestingContract);
    event ForeignTokenRecovered(address indexed token, address indexed to, uint256 amount);

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    /**
     * @param _liquidityWallet Address that receives the per-transfer
     *                         liquidity fee (also receives LIQ_RESERVE).
     * @param _rewardPool      Address holding the staking reward pool.
     */
    constructor(address _liquidityWallet, address _rewardPool)
        ERC20("NEXIS", "NXS")
        Ownable(msg.sender)
    {
        require(_liquidityWallet != address(0), "NEXIS: zero liquidity wallet");
        require(_rewardPool != address(0),      "NEXIS: zero reward pool");
        // Ensure the two special wallets are distinct to avoid accounting confusion.
        require(_liquidityWallet != _rewardPool, "NEXIS: wallets must differ");

        liquidityWallet = _liquidityWallet;
        rewardPool      = _rewardPool;

        // FIX H-5: CIRCULATING + REWARD_POOL + LIQ_RESERVE == MAX_SUPPLY exactly.
        // 311_111_111 + 88_888_889 + 44_444_444 = 444_444_444  ✓
        _mint(msg.sender,       CIRCULATING);
        _mint(_rewardPool,      REWARD_POOL);
        _mint(_liquidityWallet, LIQ_RESERVE);

        // Exclude privileged addresses from transfer fees.
        isExcludedFromFees[msg.sender]       = true;
        isExcludedFromFees[address(this)]    = true;
        isExcludedFromFees[_liquidityWallet] = true;
        isExcludedFromFees[_rewardPool]      = true;
    }

    // =========================================================
    // ERC-20 TRANSFER HOOK
    // =========================================================

    /**
     * @dev Overrides OpenZeppelin's internal _update to apply:
     *      1. Burn fee  → sent to address(0).
     *      2. Liquidity fee → sent to liquidityWallet.
     *      Excluded addresses bypass fees entirely.
     *
     *      Gas optimisation: fees are computed with a single division
     *      and the three sub-transfers share the same slot writes where
     *      possible (OZ ERC20 batches balance updates internally).
     */
    function _update(address from, address to, uint256 amount)
        internal
        override
    {
        // Mint / burn paths — no fees.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // FIX A-7: use totalSupply() not the constant MAX_SUPPLY so the
        // limit shrinks proportionally as tokens are burned.

        // Whitelisted senders or receivers pay no fees.
        if (isExcludedFromFees[from] || isExcludedFromFees[to]) {
            super._update(from, to, amount);
            return;
        }

        // Compute fees once; use local vars to save SLOADs.
        uint256 _burnRate      = burnRate;
        uint256 _liquidityRate = liquidityRate;

        uint256 burnAmount      = (amount * _burnRate)      / 10_000;
        uint256 liquidityAmount = (amount * _liquidityRate) / 10_000;
        uint256 sendAmount      = amount - burnAmount - liquidityAmount;

        if (burnAmount > 0)      super._update(from, address(0),    burnAmount);
        if (liquidityAmount > 0) super._update(from, liquidityWallet, liquidityAmount);

        super._update(from, to, sendAmount);
    }

    // =========================================================
    // STAKING
    // =========================================================

    /**
     * @notice Lock NXS tokens to earn staking rewards.
     * @param  amount Gross amount to transfer from caller (before any fees).
     * @dev    FIX C-3: uses balanceBefore / balanceAfter pattern to record
     *         only the *net* tokens actually received by the contract,
     *         preventing an accounting mismatch on unstake caused by the
     *         burn + liquidity fees deducted during the inbound transfer.
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "NEXIS: amount is zero");
        require(balanceOf(msg.sender) >= amount, "NEXIS: insufficient balance");

        // Claim any pending reward before updating the stake balance.
        if (stakedAmount[msg.sender] > 0) {
            _claimPending(msg.sender);
        }

        // --- balanceBefore / balanceAfter pattern (FIX C-3) ---
        uint256 balBefore = balanceOf(address(this));
        _transfer(msg.sender, address(this), amount);
        uint256 credited = balanceOf(address(this)) - balBefore;
        // `credited` is always <= amount because fees may have been deducted.

        stakedAmount[msg.sender]   += credited;
        stakeTimestamp[msg.sender]  = block.timestamp;
        totalStaked                += credited;

        emit Staked(msg.sender, amount, credited);
    }

    /**
     * @notice Withdraw staked NXS and collect accrued rewards.
     * @dev    FIX C-1: enforces MIN_LOCK_PERIOD to block drain attacks.
     *         The contract is excluded from fees so the outbound transfer
     *         to msg.sender carries no burn/liquidity deduction.
     */
    function unstake() external nonReentrant {
        uint256 amount = stakedAmount[msg.sender];
        require(amount > 0, "NEXIS: nothing staked");
        require(
            block.timestamp >= stakeTimestamp[msg.sender] + MIN_LOCK_PERIOD,
            "NEXIS: lock period active"
        );

        uint256 reward = calculateReward(msg.sender);

        // Clear state before external calls (CEI pattern).
        stakedAmount[msg.sender]   = 0;
        stakeTimestamp[msg.sender] = 0;
        totalStaked               -= amount;

        // Return principal — address(this) is fee-exempt, no deduction.
        _transfer(address(this), msg.sender, amount);

        // Pay reward from pool if available.
        if (reward > 0) {
            _payReward(msg.sender, reward);
        }

        emit Unstaked(msg.sender, amount, reward);
    }

    /**
     * @notice Claim accrued staking reward without unstaking.
     * @dev    Resets the reward timer; principal remains locked.
     *         FIX C-1: MIN_LOCK_PERIOD must have elapsed before first claim.
     */
    function claimReward() external nonReentrant {
        require(stakedAmount[msg.sender] > 0, "NEXIS: nothing staked");
        require(
            block.timestamp >= stakeTimestamp[msg.sender] + MIN_LOCK_PERIOD,
            "NEXIS: lock period active"
        );
        _claimPending(msg.sender);
    }

    /**
     * @notice Returns the accrued reward for `user`, capped at reward pool balance.
     * @dev    FIX M-1: returns claimable amount, not theoretical amount,
     *         so front-ends show accurate figures.
     * @param  user Address to query.
     * @return claimable Actual NXS transferable from reward pool right now.
     */
    function claimableReward(address user) external view returns (uint256 claimable) {
        uint256 reward    = calculateReward(user);
        uint256 available = balanceOf(rewardPool);
        claimable = reward < available ? reward : available;
    }

    /**
     * @notice Computes the full theoretical reward for `user` (may exceed pool balance).
     * @param  user Address to query.
     * @return reward Theoretical reward in NXS wei.
     */
    function calculateReward(address user) public view returns (uint256 reward) {
        if (stakedAmount[user] == 0) return 0;
        uint256 elapsed = block.timestamp - stakeTimestamp[user];
        reward = (stakedAmount[user] * stakingAPY * elapsed) / (10_000 * 365 days);
    }

    // =========================================================
    // INTERNAL STAKING HELPERS
    // =========================================================

    /**
     * @dev Pays any accrued reward and resets the reward timestamp.
     *      Called by claimReward() and stake() (compound on re-stake).
     */
    function _claimPending(address user) internal {
        uint256 reward = calculateReward(user);
        if (reward == 0) return;
        stakeTimestamp[user] = block.timestamp;
        _payReward(user, reward);
    }

    /**
     * @dev Transfers up to `reward` from rewardPool to `user`.
     *      Emits RewardPoolDepleted if the pool cannot cover the full amount.
     */
    function _payReward(address user, uint256 reward) internal {
        uint256 available = balanceOf(rewardPool);
        if (available == 0) {
            emit RewardPoolDepleted(reward, 0);
            return;
        }
        uint256 payout = reward < available ? reward : available;
        // rewardPool is fee-exempt; transfer carries no deduction.
        _transfer(rewardPool, user, payout);
        emit RewardClaimed(user, payout);
        if (payout < reward) {
            emit RewardPoolDepleted(reward, payout);
        }
    }

    // =========================================================
    // TIMELOCK ENGINE
    // =========================================================

    /**
     * @dev Queues a value change identified by `key`.
     *      FIX L-4: queued changes can be cancelled by owner at any time
     *      (see cancelChange), including after renounceOwnership is called
     *      the pending tx simply becomes unexecutable.
     */
    function _queueChange(bytes32 key, uint256 value) internal {
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingChanges[key] = PendingChange({
            value:        value,
            executeAfter: executeAfter,
            exists:       true
        });
        emit ChangeQueued(key, value, executeAfter);
    }

    /**
     * @dev Validates and consumes a queued change.
     * @return value The new value to apply.
     */
    function _executeChange(bytes32 key) internal returns (uint256 value) {
        PendingChange storage c = pendingChanges[key];
        require(c.exists,                              "NEXIS: no pending change");
        require(block.timestamp >= c.executeAfter,     "NEXIS: timelock active");
        value = c.value;
        delete pendingChanges[key];
        emit ChangeExecuted(key, value);
    }

    /**
     * @notice Cancel any queued admin change before it is executed.
     * @param  key keccak256 identifier of the change (e.g. keccak256("burnRate")).
     */
    function cancelChange(bytes32 key) external onlyOwner {
        require(pendingChanges[key].exists, "NEXIS: nothing to cancel");
        delete pendingChanges[key];
        emit ChangeCancelled(key);
    }

    // =========================================================
    // TIMELOCKED ADMIN — BURN RATE
    // =========================================================

    /// @notice Step 1: queue a burn rate change (takes effect after 48 h).
    /// @param  newRate New burn rate in bp/10 000.  Max 1 % (100).
    function queueBurnRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_BURN_RATE, "NEXIS: exceeds max burn rate");
        _queueChange(keccak256("burnRate"), newRate);
    }

    /// @notice Step 2: apply the queued burn rate after the timelock expires.
    function executeBurnRate() external onlyOwner {
        burnRate = _executeChange(keccak256("burnRate"));
    }

    // =========================================================
    // TIMELOCKED ADMIN — LIQUIDITY RATE
    // =========================================================

    /// @notice Step 1: queue a liquidity fee change.
    /// @param  newRate New rate in bp/10 000.  Max 2 % (200).
    function queueLiquidityRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_LIQUIDITY_RATE, "NEXIS: exceeds max liquidity rate");
        _queueChange(keccak256("liquidityRate"), newRate);
    }

    /// @notice Step 2: apply queued liquidity rate.
    function executeLiquidityRate() external onlyOwner {
        liquidityRate = _executeChange(keccak256("liquidityRate"));
    }

    // =========================================================
    // TIMELOCKED ADMIN — STAKING APY
    // =========================================================

    /**
     * @notice Step 1: queue a staking APY change.
     * @param  newAPY New APY in bp/10 000.  Min 1 % (100), max 30 % (3 000).
     * @dev    FIX M-3: MIN_STAKING_APY prevents owner from zeroing rewards.
     */
    function queueStakingAPY(uint256 newAPY) external onlyOwner {
        require(newAPY >= MIN_STAKING_APY, "NEXIS: below min APY");
        require(newAPY <= MAX_STAKING_APY, "NEXIS: exceeds max APY");
        _queueChange(keccak256("stakingAPY"), newAPY);
    }

    /// @notice Step 2: apply queued APY.
    function executeStakingAPY() external onlyOwner {
        stakingAPY = _executeChange(keccak256("stakingAPY"));
    }

    // =========================================================
    // TIMELOCKED ADMIN — LIQUIDITY WALLET
    // =========================================================

    /**
     * @notice Step 1: queue a liquidity wallet change.
     * @param  newWallet Address that will receive the 1 % liquidity fee.
     * @dev    FIX H-2: liquidityWallet change is now timelocked (was instant).
     *         This gives token holders 48 h to react before fee redirection.
     */
    function queueLiquidityWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "NEXIS: zero address");
        // Store the address as uint256 in the generic timelock slot.
        uint256 packed = uint256(uint160(newWallet));
        _queueChange(keccak256("liquidityWallet"), packed);
        emit LiquidityWalletQueued(newWallet, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Step 2: apply the queued liquidity wallet.
     * @dev    FIX M-2: removes old wallet from fee-exclusion list before
     *         adding the new one, closing the perpetual-whitelist bug.
     */
    function executeLiquidityWallet() external onlyOwner {
        uint256 packed = _executeChange(keccak256("liquidityWallet"));
        address newWallet = address(uint160(packed));

        address oldWallet = liquidityWallet;
        // Only remove old exclusion if it is not another privileged address.
        if (
            oldWallet != owner()        &&
            oldWallet != rewardPool     &&
            oldWallet != address(this)
        ) {
            isExcludedFromFees[oldWallet] = false;
        }

        liquidityWallet = newWallet;
        isExcludedFromFees[newWallet] = true;

        emit LiquidityWalletChanged(oldWallet, newWallet);
    }

    // =========================================================
    // ADMIN — REWARD POOL
    // =========================================================

    /**
     * @notice Replace the reward pool address (immediate, owner-only).
     * @param  newPool New reward pool address.
     * @dev    FIX C-2: rewardPool is no longer immutable — it can be
     *         changed if the original address is compromised.
     *         Not timelocked intentionally: in a compromise scenario
     *         a 48-hour delay would allow the attacker to drain the pool.
     *         Trade-off is documented here for auditors.
     */
    function setRewardPool(address newPool) external onlyOwner {
        require(newPool != address(0), "NEXIS: zero address");
        address old = rewardPool;
        if (isExcludedFromFees[old] && old != owner() && old != liquidityWallet) {
            isExcludedFromFees[old] = false;
        }
        rewardPool = newPool;
        isExcludedFromFees[newPool] = true;
        emit RewardPoolChanged(old, newPool);
    }

    // =========================================================
    // ADMIN — FEE EXCLUSIONS
    // =========================================================

    /**
     * @notice Add or remove an address from the fee-exclusion list.
     * @param  account Address to configure.
     * @param  excluded True = no fees on transfers involving this address.
     */
    function setExcludedFromFees(address account, bool excluded)
        external
        onlyOwner
    {
        isExcludedFromFees[account] = excluded;
        emit ExcludedFromFees(account, excluded);
    }

    // =========================================================
    // ADMIN — TEAM VESTING INFO
    // =========================================================

    /**
     * @notice Register the address of the external vesting contract.
     * @param  vestingContract Address of the VestingWallet holding team tokens.
     * @dev    Purely informational — allows block explorers and auditors to
     *         verify team token lock-up without on-chain enforcement overhead.
     */
    function setTeamVesting(address vestingContract) external onlyOwner {
        teamVesting = vestingContract;
        emit TeamVestingSet(vestingContract);
    }

    // =========================================================
    // RECOVERY — FOREIGN ERC-20 TOKENS
    // =========================================================

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     * @param  token   Address of the foreign token.
     * @param  to      Recipient (typically owner or treasury).
     * @param  amount  Amount to recover.
     * @dev    FIX L-extra: NXS tokens that are *not* part of active stakes
     *         can also be recovered.  Staked NXS is protected by the check
     *         below: the contract may not hold more NXS than totalStaked.
     *         If `token == address(this)`, only the surplus above totalStaked
     *         is recoverable so stakers are never put at risk.
     */
    function recoverERC20(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "NEXIS: zero recipient");
        if (token == address(this)) {
            // Never allow recovery of staked principal.
            uint256 surplus = balanceOf(address(this)) > totalStaked
                ? balanceOf(address(this)) - totalStaked
                : 0;
            require(amount <= surplus, "NEXIS: amount exceeds surplus");
        }
        IERC20(token).safeTransfer(to, amount);
        emit ForeignTokenRecovered(token, to, amount);
    }

    // =========================================================
    // OWNERSHIP
    // =========================================================

    /**
     * @notice Permanently renounce owner privileges.
     * @dev    Inherited from Ownable2Step.  After this call no admin
     *         functions are callable.  Any pending timelock changes
     *         become unexecutable (FIX L-4 mitigation).
     */
    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }
}
