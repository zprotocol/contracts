// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interface/ITreasurer.sol";
import "./ZkHarvestToken.sol";

contract ZkHarvest is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  modifier onlyDev() {
    require(msg.sender == dev, "ZkHarvest Dev: caller is not the dev");
    _;
  }

  modifier onlyFeeCollector() {
    require(
      msg.sender == feeCollector,
      "ZkHarvest Fee Collector: caller is not the fee collector"
    );
    _;
  }

  // Category informations
  struct CatInfo {
    // Allocation points assigned to this category
    uint256 allocPoints;
    // Total pool allocation points. Must be at all time equal to the sum of all
    // pool allocation points in this category.
    uint256 totalPoolAllocPoints;
    // Name of this category
    string name;
  }

  // User informations
  struct UserInfo {
    // Amount of tokens deposited
    uint256 amount;
    // Reward debt.
    //
    // We do some fancy math here. Basically, any point in time, the amount of ZKHs
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accZKHPerShare) - user.rewardDebt + user.locked
    //
    // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
    //   1. The pool's `accZKHPerShare` (and `lastRewardTime`) gets updated.
    //   2. User receives the available reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
    uint256 rewardDebt;
    // Time at which user can harvest this pool again
    uint256 nextHarvestTime;
    // Reward that will be unlockable when nextHarvestTime is reached
    uint256 lockedReward;
  }

  // Pool informations
  struct PoolInfo {
    // Address of this pool's token
    IERC20 token;
    // Category ID of this pool
    uint256 catId;
    // Allocation points assigned to this pool
    uint256 allocPoints;
    // Last time where ZKH was distributed.
    uint256 lastRewardTime;
    // Accumulated ZKH per share, times 1e18. Used for rewardDebt calculations.
    uint256 accZKHPerShare;
    // Deposit fee for this pool, in basis points (from 0 to 10000)
    uint256 depositFeeBP;
    // Harvest interval for this pool, in seconds
    uint256 harvestInterval;
  }

  // The following limits exist to ensure that the owner of ZkHarvest will
  // only modify the contract's settings in a specific range of value, that
  // the users can see by themselves at any time.

  // Maximum harvest interval that can be set
  uint256 public constant MAX_HARVEST_INTERVAL = 24 hours;
  // Maximum deposit fee that can be set
  uint256 public constant MAX_DEPOSIT_FEE_BP = 400;
  // Maximum ZKH reward per second that can be set
  uint256 public constant MAX_ZKH_PER_SECOND = 4629629629629629630; // ~400k/d

  // The informations of each category
  CatInfo[] public catInfo;
  // The pools in each category. Used in front.
  mapping(uint256 => uint256[]) public catPools;
  // Total category allocation points. Must be at all time equal to the sum of
  // all category allocation points.
  uint256 public totalCatAllocPoints = 0;

  // The informations of each pool
  PoolInfo[] public poolInfo;
  // Mapping to keep track of which token has been added, and its index in the
  // array.
  mapping(address => uint256) public tokensAdded;
  // The informations of each user, per pool
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;

  // The ZKH token
  ZkHarvestToken public immutable zkh;
  // The Treasurer. Handles rewards.
  ITreasurer public immutable treasurer;
  // ZKH minted to devs per second
  uint256 public devZKHPerSecond;
  // ZKH minted as rewards per second
  uint256 public rewardZKHPerSecond;
  // The address to send dev funds to
  address public dev;
  // The address to send fees to
  address public feeCollector;
  // Launch time
  uint256 public startTime;
  // Farming duration, in seconds
  uint256 public farmingDuration;

  event CategoryCreate(uint256 id, string indexed name, uint256 allocPoints);
  event CategoryEdit(uint256 id, uint256 allocPoints);

  event PoolCreate(
    address indexed token,
    uint256 indexed catId,
    uint256 allocPoints,
    uint256 depositFeeBP,
    uint256 harvestInterval
  );
  event PoolEdit(
    address indexed token,
    uint256 indexed catId,
    uint256 allocPoints,
    uint256 depositFeeBP,
    uint256 harvestInterval
  );

  event Deposit(
    address indexed user,
    uint256 indexed pid,
    uint256 amount,
    uint256 fee
  );
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(
    address indexed user,
    uint256 indexed pid,
    uint256 amount
  );

  constructor(
    ZkHarvestToken _zkh,
    ITreasurer _treasurer,
    address _dev,
    address _feeCollector,
    uint256 _initZKHPerSecond,
    uint256 _startTime
  ) {
    zkh = _zkh;
    treasurer = _treasurer;
    require(
      _initZKHPerSecond <= MAX_ZKH_PER_SECOND,
      "ZkHarvest: too high ZKH reward"
    );
    devZKHPerSecond = _initZKHPerSecond / 10;
    rewardZKHPerSecond = _initZKHPerSecond - devZKHPerSecond;
    require(_dev != address(0), "ZkHarvest Dev: null address not permitted");
    dev = _dev;
    require(
      _feeCollector != address(0),
      "ZkHarvest Fee Collector: null address not permitted"
    );
    feeCollector = _feeCollector;
    startTime = _startTime;
    if (startTime < block.timestamp) {
      startTime = block.timestamp;
    }
    farmingDuration =
      (_zkh.maxSupply() - _zkh.totalMinted()) /
      _initZKHPerSecond;
  }

  // Update the starting time. Can only be called by the owner.
  // Can only be called before current starting time.
  // Can only be called if there is no pool registered.
  function updateStartTime(uint256 _newStartTime) external onlyOwner {
    require(
      block.timestamp < startTime,
      "ZkHarvest: Cannot change startTime after farming has already started."
    );
    require(
      poolInfo.length == 0,
      "ZkHarvest: Cannot change startTime after a pool has been registered."
    );
    require(
      _newStartTime > block.timestamp,
      "ZkHarvest: Cannot change startTime with a past timestamp."
    );
    startTime = _newStartTime;
  }

  // Update the dev address. Can only be called by the dev.
  function updateDev(address _newDev) public onlyDev {
    require(_newDev != address(0), "ZkHarvest Dev: null address not permitted");
    dev = _newDev;
  }

  // Update the fee address. Can only be called by the fee collector.
  function updateFeeCollector(
    address _newFeeCollector
  ) public onlyFeeCollector {
    require(
      _newFeeCollector != address(0),
      "ZkHarvest Fee Collector: null address not permitted"
    );
    feeCollector = _newFeeCollector;
  }

  // Update the ZKH per second reward. Can only be called by the owner.
  function updateZKHPerSecond(
    uint256 _newZKHPerSecond,
    bool _withUpdate
  ) public onlyOwner {
    require(
      _newZKHPerSecond <= MAX_ZKH_PER_SECOND,
      "ZkHarvest: too high ZKH reward"
    );

    if (_withUpdate) {
      massUpdatePools();
    }
    devZKHPerSecond = _newZKHPerSecond / 10;
    rewardZKHPerSecond = _newZKHPerSecond - devZKHPerSecond;
    _updateEndTime();
  }

  function elapsedTime() public view returns (uint256) {
    if (block.timestamp > startTime) {
      return block.timestamp - startTime;
    }
    return 0;
  }

  function _updateEndTime() internal {
    farmingDuration =
      elapsedTime() +
      (zkh.maxSupply() - zkh.totalMinted()) /
      ZKHPerSecond();
  }

  function updateEndTime(bool _withUpdate) external onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    _updateEndTime();
  }

  // View function to check the total ZKH generated every second
  function ZKHPerSecond() public view returns (uint256) {
    return devZKHPerSecond + rewardZKHPerSecond;
  }

  // View function to check if user can harvest pool
  function canHarvest(
    uint256 _poolId,
    address _user
  ) public view returns (bool) {
    return block.timestamp >= userInfo[_poolId][_user].nextHarvestTime;
  }

  // Create a new pool category. Can only be called by the owner.
  function createCategory(
    string calldata _name,
    uint256 _allocPoints,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }

    totalCatAllocPoints += _allocPoints;

    catInfo.push(
      CatInfo({name: _name, allocPoints: _allocPoints, totalPoolAllocPoints: 0})
    );

    emit CategoryCreate(catInfo.length - 1, _name, _allocPoints);
  }

  // Edit a pool category. Can only be called by the owner.
  function editCategory(
    uint256 _catId,
    uint256 _allocPoints,
    bool _withUpdate
  ) public onlyOwner {
    require(_catId < catInfo.length, "ZkHarvest: category does not exist");

    if (_withUpdate) {
      massUpdatePools();
    }

    totalCatAllocPoints =
      totalCatAllocPoints -
      catInfo[_catId].allocPoints +
      _allocPoints;
    catInfo[_catId].allocPoints = _allocPoints;

    emit CategoryEdit(_catId, _allocPoints);
  }

  // Create a new token pool, after checking that it doesn't already exist.
  // Can only be called by owner.
  function createPool(
    uint256 _catId,
    IERC20 _token,
    uint256 _allocPoints,
    uint256 _depositFeeBP,
    uint256 _harvestInterval,
    bool _withUpdate
  ) public onlyOwner {
    require(_catId < catInfo.length, "ZkHarvest: category does not exist");
    require(
      _harvestInterval <= MAX_HARVEST_INTERVAL,
      "ZkHarvest: too high harvest interval"
    );
    require(
      _depositFeeBP <= MAX_DEPOSIT_FEE_BP,
      "ZkHarvest: too high deposit fee"
    );

    address tokenAddress = address(_token);
    require(
      tokensAdded[tokenAddress] == 0,
      "ZkHarvest: token already registered"
    );

    if (_withUpdate) {
      massUpdatePools();
    }

    uint256 lastRewardTime = block.timestamp > startTime
      ? block.timestamp
      : startTime;

    catInfo[_catId].totalPoolAllocPoints += _allocPoints;

    tokensAdded[tokenAddress] = poolInfo.length + 1;
    poolInfo.push(
      PoolInfo({
        catId: _catId,
        token: _token,
        allocPoints: _allocPoints,
        lastRewardTime: lastRewardTime,
        accZKHPerShare: 0,
        depositFeeBP: _depositFeeBP,
        harvestInterval: _harvestInterval
      })
    );
    catPools[_catId].push(poolInfo.length - 1);

    emit PoolCreate(
      tokenAddress,
      _catId,
      _allocPoints,
      _depositFeeBP,
      _harvestInterval
    );
  }

  // Edits a new token pool. Can only be called by owner.
  function editPool(
    uint256 _poolId,
    uint256 _allocPoints,
    uint256 _depositFeeBP,
    uint256 _harvestInterval,
    bool _withUpdate
  ) public onlyOwner {
    require(_poolId < poolInfo.length, "ZkHarvest: pool does not exist");
    require(
      _harvestInterval <= MAX_HARVEST_INTERVAL,
      "ZkHarvest: too high harvest interval"
    );
    require(
      _depositFeeBP <= MAX_DEPOSIT_FEE_BP,
      "ZkHarvest: too high deposit fee"
    );

    if (_withUpdate) {
      massUpdatePools();
    }

    uint256 catId = poolInfo[_poolId].catId;

    catInfo[catId].totalPoolAllocPoints =
      catInfo[catId].totalPoolAllocPoints -
      poolInfo[_poolId].allocPoints +
      _allocPoints;
    poolInfo[_poolId].allocPoints = _allocPoints;
    poolInfo[_poolId].depositFeeBP = _depositFeeBP;
    poolInfo[_poolId].harvestInterval = _harvestInterval;

    emit PoolEdit(
      address(poolInfo[_poolId].token),
      poolInfo[_poolId].catId,
      _allocPoints,
      _depositFeeBP,
      _harvestInterval
    );
  }

  function getMultiplier(
    uint256 _from,
    uint256 _to
  ) public view returns (uint256) {
    uint256 _endTime = endTime();
    if (_from >= _endTime) {
      return 0;
    }
    if (_to > _endTime) {
      return _endTime - _from;
    }
    return _to - _from;
  }

  // Internal function to dispatch pool reward for sender.
  // Does one of two things:
  // - Reward the user through treasurer
  // - Lock up rewards for later harvest
  function _dispatchReward(uint256 _poolId) internal {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][msg.sender];

    if (user.nextHarvestTime == 0) {
      user.nextHarvestTime = block.timestamp + pool.harvestInterval;
    }

    uint256 pending = (user.amount * pool.accZKHPerShare) /
      1e18 -
      user.rewardDebt;
    if (block.timestamp >= user.nextHarvestTime) {
      if (pending > 0 || user.lockedReward > 0) {
        uint256 totalReward = pending + user.lockedReward;

        user.lockedReward = 0;
        user.nextHarvestTime = block.timestamp + pool.harvestInterval;

        treasurer.rewardUser(msg.sender, totalReward);
      }
    } else if (pending > 0) {
      user.lockedReward += pending;
    }
  }

  // Deposits tokens into a pool.
  function deposit(uint256 _poolId, uint256 _amount) public nonReentrant {
    PoolInfo storage pool = poolInfo[_poolId];
    require(pool.allocPoints != 0, "ZkHarvest Deposit: pool is disabled");
    require(
      catInfo[pool.catId].allocPoints != 0,
      "ZkHarvest Deposit: category is disabled"
    );
    UserInfo storage user = userInfo[_poolId][msg.sender];

    updatePool(_poolId);
    _dispatchReward(_poolId);

    uint256 depositFee = (_amount * pool.depositFeeBP) / 1e4;
    if (_amount > 0) {
      pool.token.safeTransferFrom(msg.sender, address(this), _amount);

      if (pool.depositFeeBP > 0) {
        pool.token.safeTransfer(feeCollector, depositFee);
        user.amount += _amount - depositFee;
      } else {
        user.amount += _amount;
      }
      user.nextHarvestTime = block.timestamp + pool.harvestInterval;
    }
    user.rewardDebt = (user.amount * pool.accZKHPerShare) / 1e18;

    emit Deposit(msg.sender, _poolId, _amount, depositFee);
  }

  // Withdraw tokens from a pool.
  function withdraw(uint256 _poolId, uint256 _amount) public nonReentrant {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][msg.sender];

    require(user.amount >= _amount, "ZkHarvest: bad withdrawal");
    updatePool(_poolId);
    _dispatchReward(_poolId);

    user.amount -= _amount;
    user.rewardDebt = (user.amount * pool.accZKHPerShare) / 1e18;

    if (_amount > 0) {
      pool.token.safeTransfer(msg.sender, _amount);
    }

    emit Withdraw(msg.sender, _poolId, _amount);
  }

  // EMERGENCY ONLY. Withdraw tokens, give rewards up.
  function emergencyWithdraw(uint256 _poolId) public nonReentrant {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][msg.sender];

    pool.token.safeTransfer(address(msg.sender), user.amount);
    emit EmergencyWithdraw(msg.sender, _poolId, user.amount);
    user.amount = 0;
    user.rewardDebt = 0;
    user.lockedReward = 0;
    user.nextHarvestTime = 0;
  }

  // Update all pool at ones. Watch gas spendings.
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 poolId = 0; poolId < length; poolId++) {
      updatePool(poolId);
    }
  }

  // Update a single pool's reward variables, and mints rewards.
  // If the pool has no tokenSupply, then the reward will be fully sent to the
  // dev fund. This is done so that the amount of tokens minted every second
  // is stable, and the end of farming is predictable and only impacted by
  // updateZKHPerSecond.
  function updatePool(uint256 _poolId) public {
    PoolInfo storage pool = poolInfo[_poolId];
    if (
      block.timestamp <= pool.lastRewardTime ||
      pool.allocPoints == 0 ||
      catInfo[pool.catId].allocPoints == 0
    ) {
      return;
    }
    uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
    if (multiplier == 0) {
      pool.lastRewardTime = block.timestamp;
      return;
    }
    uint256 tokenSupply = pool.token.balanceOf(address(this));
    CatInfo storage cat = catInfo[pool.catId];
    uint256 userReward = (((multiplier *
      rewardZKHPerSecond *
      pool.allocPoints) / cat.totalPoolAllocPoints) * cat.allocPoints) /
      totalCatAllocPoints;
    uint256 devReward = (((multiplier * devZKHPerSecond * pool.allocPoints) /
      cat.totalPoolAllocPoints) * cat.allocPoints) / totalCatAllocPoints;
    pool.lastRewardTime = block.timestamp;
    if (tokenSupply == 0) {
      zkh.mint(dev, userReward);
    } else {
      pool.accZKHPerShare += (userReward * 1e18) / tokenSupply;
      zkh.mint(address(treasurer), userReward);
    }
    zkh.mint(dev, devReward);
  }

  /**
   *
   * @param _poolId the pool id to check pending rewards for
   * @param _user the user to check pending rewards for
   * @return pendingReward
   * @return currentTimestamp
   */
  function pendingReward(
    uint256 _poolId,
    address _user
  ) external view returns (uint256, uint256) {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][_user];
    CatInfo storage cat = catInfo[pool.catId];
    uint256 accZKHPerShare = pool.accZKHPerShare;
    uint256 tokenSupply = pool.token.balanceOf(address(this));

    if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
      uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
      if (multiplier != 0) {
        uint256 userReward = (((multiplier *
          rewardZKHPerSecond *
          pool.allocPoints) / cat.totalPoolAllocPoints) * cat.allocPoints) /
          totalCatAllocPoints;
        accZKHPerShare += (userReward * 1e18) / tokenSupply;
      }
    }
    return (
      (user.amount * accZKHPerShare) /
        1e18 -
        user.rewardDebt +
        user.lockedReward,
      block.timestamp
    );
  }

  function poolsLength() external view returns (uint256) {
    return poolInfo.length;
  }

  function categoriesLength() external view returns (uint256) {
    return catInfo.length;
  }

  function poolsInCategory(
    uint256 _catId
  ) external view returns (uint256[] memory) {
    return catPools[_catId];
  }

  function endTime() public view returns (uint256) {
    return startTime + farmingDuration;
  }
}
