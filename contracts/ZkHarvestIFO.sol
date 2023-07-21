// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./ZkHarvestToken.sol";

contract ZkHarvestIFO is Ownable, ReentrancyGuard {
  uint256 constant MAX_REFERRAL_REWARD_BP = 1500;

  // All the states the IFO can be in
  // CLOSED can mean two things:
  // - raisedAmount >= minAmountToRaise => Closed and claims open
  // - raisedAmount < minAmountToRaise => Closed and refunds open
  enum State {
    NOT_STARTED,
    OPEN,
    CLOSED
  }


  event StateChange(State newState);
  event Commit(address indexed account, uint256 amount, address referral);
  event Claim(address indexed account, uint256 amount);
  event RewardsClaim(address indexed account, uint256 amount);
  event Refund(address indexed account, uint256 amount);

  // Current state of this IFO
  State public state = State.NOT_STARTED;

  // The token to receive
  ZkHarvestToken public token;

  // Team address, capable of withdrawing funds
  address payable public team;

  // Maximum amount to ETH that can be raised
  uint256 public amountToRaise;
  // Minimum amount of ETH that must be raised for the IFO to succeed
  uint256 public minAmountToRaise;
  // Supply of tokens to distribute
  uint256 public supply;

  // Minimum amount a wallet can commit
  uint256 public minAmountPerWallet;
  // Maximum amount a wallet can commit
  uint256 public maxAmountPerWallet;

  // Referral reward in basis points (1 = 0.01%)
  uint256 public referralRewardBP;

  // Amount of ETH committed per wallet
  mapping(address => uint256) public committedAmountPerWallet;
  // Total amount of ETH committed
  uint256 public raisedAmount;

  // Amount of ETH claimable as rewards per wallet (only if IFO succeeds)
  mapping(address => uint256) public referralRewards;
  // Total amount of ETH claimable as rewards (only if IFO succeeds)
  uint256 public totalReferralRewards;

  // Has wallet finalized?
  mapping(address => bool) public hasFinalized;
  // Has wallet claimed its rewards?
  mapping(address => bool) public hasClaimedReferralRewards;

  // Has team withdrawn?
  bool hasTeamWithdrawn;

  modifier onlyState(State _state) {
    require(state == _state, "wrong state for this action");
    _;
  }

  modifier onlyTeam() {
    require(_msgSender() == team, "caller is not team");
    _;
  }

  constructor(ZkHarvestToken _token, address payable _team) {
    token = _token;
    team = _team;
  }

  /**
   * Sets the team address, can only be called ny current team address
   * @param _team new team address
   */
  function setTeam(address payable _team) external onlyTeam {
    team = _team;
  }

  /**
   * Configures the IFO. Can only be done while IFO is not started.
   * @param _supply token supply to distribute
   * @param _amountToRaise max amount of ETH to raise
   * @param _minAmountToRaise min amount of ETH to consider IFO successful
   * @param _minAmountPerWallet min amount of ETH a wallet can commit
   * @param _maxAmountPerWallet max amount of ETH a wallet can commit
   * @param _referralRewardBP referral rewards in basis points
   */
  function configure(
    uint256 _supply,
    uint256 _amountToRaise,
    uint256 _minAmountToRaise,
    uint256 _minAmountPerWallet,
    uint256 _maxAmountPerWallet,
    uint256 _referralRewardBP
  ) external onlyOwner onlyState(State.NOT_STARTED) {
    require(_supply != 0, "wrong configuration: supply");
    require(_amountToRaise != 0, "wrong configuration: amountToRaise");
    require(
      _amountToRaise >= _minAmountToRaise,
      "wrong configuration: minAmountToRaise"
    );
    require(
      token.balanceOf(address(this)) >= _supply,
      "wrong configuration: supply above balance"
    );
    require(
      _minAmountPerWallet != 0,
      "wrong configuration: minAmountPerWallet"
    );
    require(
      _maxAmountPerWallet >= _minAmountPerWallet,
      "wrong configuration: min amount above max amount"
    );
    require(
      _referralRewardBP <= MAX_REFERRAL_REWARD_BP,
      "wrong configuration: referral reward above max"
    );
    supply = _supply;
    amountToRaise = _amountToRaise;
    minAmountToRaise = _minAmountToRaise;

    minAmountPerWallet = _minAmountPerWallet;
    maxAmountPerWallet = _maxAmountPerWallet;

    referralRewardBP = _referralRewardBP;
  }

  /**
   * Opens the IFO. Only when IFO is in NOT_STARTED state. Only owner.
   */
  function open() external onlyOwner onlyState(State.NOT_STARTED) {
    require(amountToRaise != 0, "not configured");
    state = State.OPEN;
    emit StateChange(State.OPEN);
  }

  /**
   * Closes the IFO. Only when IFO is in OPEN state. Only owner.
   */
  function close() external onlyOwner onlyState(State.OPEN) {
    state = State.CLOSED;
    emit StateChange(State.CLOSED);
  }

  /**
   * Commits msg.value ETH to the IFO, with optional referral address.
   * @param _referral referral address. 0x0 means no referral.
   */
  function _commit(address _referral) internal {
    require(
      msg.value + raisedAmount <= amountToRaise,
      "would go over max amount to raise"
    );
    uint256 committedAmount = committedAmountPerWallet[_msgSender()] +
      msg.value;
    require(committedAmount >= minAmountPerWallet, "msg.value too small");
    require(committedAmount <= maxAmountPerWallet, "msg.value too big");

    committedAmountPerWallet[_msgSender()] = committedAmount;
    raisedAmount += msg.value;

    if (_referral != address(0) && referralRewardBP > 0) {
      uint256 reward = (referralRewardBP * msg.value) / 10000;
      referralRewards[_referral] += reward;
      totalReferralRewards += reward;
    }

    emit Commit(_msgSender(), msg.value, _referral);
  }

  /**
   * Commits msg.value ETH without referral. Only when state is OPEN.
   */
  function commit() external payable onlyState(State.OPEN) nonReentrant {
    _commit(address(0));
  }

  /**
   * Commits msg.value ETH with optional referral. Only when state is OPEN.
   * @param _referral referral addres. 0x0 means no referral.
   */
  function commitWithReferral(
    address _referral
  ) external payable onlyState(State.OPEN) nonReentrant {
    if (_referral == _msgSender()) {
      _commit(address(0));
    } else {
      _commit(_referral);
    }
  }

  /**
   * Returns balance of claimable tokens for `_account`. Should only be used
   * in CLOSED state, in case of a successful IFO.
   * @param _account account to check the balance of
   */
  function _claimableTokens(address _account) internal view returns (uint256) {
    if (hasFinalized[_account]) {
      return 0;
    }
    return (committedAmountPerWallet[_account] * supply) / amountToRaise;
  }

  /**
   * Returns balance of claimable tokens for `account`.
   * @param _account account to check the balance of
   */
  function claimableTokens(address _account) external view returns (uint256) {
    if (state != State.CLOSED || raisedAmount < minAmountToRaise) {
      return 0;
    }
    return _claimableTokens(_account);
  }

  /**
   * Claims the claimabale tokens for msg.sender. Only when state is CLOSED,
   * and when IFO is succesful.
   */
  function claim() external onlyState(State.CLOSED) nonReentrant {
    require(
      raisedAmount >= minAmountToRaise,
      "raise goal not reached; use 'refund' to get your deposit back"
    );

    uint256 amountToClaim = _claimableTokens(_msgSender());
    require(amountToClaim > 0, "no tokens to claim");

    token.transfer(_msgSender(), amountToClaim);
    hasFinalized[_msgSender()] = true;
    emit Claim(_msgSender(), amountToClaim);
  }

  /**
   * Returns balance of refundable ETH for `_account`. Should only be used
   * in CLOSED state, in case of failed IFO.
   * @param _account account to check the refundable balance of.
   */
  function _refundableAmount(address _account) internal view returns (uint256) {
    if (hasFinalized[_account]) {
      return 0;
    }
    return committedAmountPerWallet[_account];
  }

  /**
   * Returns balance of refundable ETH for `_account`.
   * @param _account account to check the refundable balance of.
   */
  function refundableAmount(address _account) external view returns (uint256) {
    if (state != State.CLOSED || raisedAmount >= minAmountToRaise) {
      return 0;
    }
    return _refundableAmount(_account);
  }

  /**
   * Refunds committed ETH for msg.sender. Only when state is CLOSED, and IFO
   * is failed.
   */
  function refund() external onlyState(State.CLOSED) nonReentrant {
    require(
      raisedAmount < minAmountToRaise,
      "raise goal reached; use 'claim' to get your tokens"
    );

    uint256 amountToRefund = _refundableAmount(_msgSender());
    require(amountToRefund > 0, "nothing to refund");

    (bool success, ) = payable(_msgSender()).call{value: amountToRefund}("");
    require(success, "failed to refund");
    hasFinalized[_msgSender()] = true;
    emit Refund(_msgSender(), amountToRefund);
  }

    /**
   * Returns balance of claimable rewards for `_account`. Should only be used
   * in CLOSED state, in case of a successful IFO.
   * @param _account account to check the balance of
   */
  function _claimableRewards(address _account) internal view returns (uint256) {
    if (hasClaimedReferralRewards[_account]) {
      return 0;
    }
    return referralRewards[_account];
  }

  /**
   * Returns balance of claimable rewards for `account`.
   * @param _account account to check the balance of
   */
  function claimableRewards(address _account) external view returns (uint256) {
    if (state != State.CLOSED || raisedAmount < minAmountToRaise) {
      return 0;
    }
    return _claimableRewards(_account);
  }

  /**
   * Claims the claimabale rewards for msg.sender. Only when state is CLOSED,
   * and when IFO is succesful.
   */
  function claimRewards() external onlyState(State.CLOSED) nonReentrant {
    require(
      raisedAmount >= minAmountToRaise,
      "raise goal not reached; no rewards to claim"
    );

    uint256 amountToReward = _claimableRewards(_msgSender());
    require(amountToReward > 0, "nothing to claim");

    (bool success, ) = payable(_msgSender()).call{value: amountToReward}("");
    require(success, "failed to reward");
    hasClaimedReferralRewards[_msgSender()] = true;
    emit RewardsClaim(_msgSender(), amountToReward);
  }

  /**
   * Withdraws committed ETH (minus referral rewards). Only team.
   */
  function withdraw() external onlyState(State.CLOSED) onlyTeam {
    require(
      raisedAmount >= minAmountToRaise,
      "raise goal not reached; team cannot withdraw"
    );
    require(!hasTeamWithdrawn, "team already withdrew");

    uint256 amountToWithdraw = raisedAmount - totalReferralRewards;
    (bool success, ) = team.call{value: amountToWithdraw}("");
    require(success, "failed to withdraw");

    hasTeamWithdrawn = true;
  }

  /**
   * Returns the amount of unsold tokens. Should only be called when state is
   * CLOSED.
   */
  function _unsoldTokens() internal view returns (uint256) {
    if (
      raisedAmount >= minAmountToRaise
    ) {
      return token.balanceOf(address(this)) - (raisedAmount * supply / amountToRaise);
    }
    return token.balanceOf(address(this));
  }

  /**
   * Burns all unsold tokens. That means all supply in case IFO is failed.
   * Only team.
   */
  function burnUnsoldTokens() external onlyState(State.CLOSED) onlyTeam {
    uint256 unsoldTokens = _unsoldTokens();
    require(unsoldTokens > 0, "no tokens unsold");

    token.burn(unsoldTokens);
  }
}
