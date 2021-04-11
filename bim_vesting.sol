// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () internal {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @dev BIM Vesting contract
 */
contract BIMVesting is Ownable, IBIMVesting {
    using SafeMath for uint;
    using SafeERC20 for IBIMToken;

    uint256 internal constant DAY = 10; // @dev MODIFY TO 86400 BEFORE PUBLIC RELEASE
    uint256 internal constant MONTH = DAY * 30;
    
    IBIMToken public BIMContract;
    IERC20 public BIMLockupContract;

    // @dev vestable group
    mapping(address => bool) public vestableGroup;
    
    modifier onlyVestableGroup() {
        require(vestableGroup[msg.sender], "not in vestable group");
        _;
    }
    
    // @dev vesting assets are grouped by day
    struct Round {
        mapping (address => uint256) balances;
        uint startDate;
    }
    
    /// @dev round index mapping
    mapping (int256 => Round) public rounds;
    /// @dev a monotonic increasing index
    int256 public currentRound = 0;

    /// @dev current vested BIMS    
    mapping (address => uint256) private balances;

    constructor(IBIMToken bimContract, IERC20 bimLockupContract) 
        public {
        BIMContract = bimContract;
        BIMLockupContract = bimLockupContract;
        rounds[0].startDate = block.timestamp;
    }
    
    /**
     * @dev set or remove address to vestable group
     */
    function setVestable(address account, bool allow) external onlyOwner {
        vestableGroup[account] = allow;
        if (allow) {
            emit Vestable(account);
        }  else {
            emit Unvestable(account);
        }
    }

    /**
     * @dev vest some BIM tokens for an account
     * Contracts that will call vest function(vestable group):
     * 
     * 1. LPStaking
     * 2. EHCStaking
     */
    function vest(address account, uint256 amount) external override onlyVestableGroup {
        update();

        rounds[currentRound].balances[account] += amount;
        balances[account] += amount;
        
        // emit amount vested
        emit Vested(account, amount);
    }
    
    /**
     * @dev check total vested bims
     */
    function checkVestedBims(address account) public view returns(uint256) {
        return balances[account];
    }
    
    /**
     * @dev check current locked BIMS
     */
    function checkLockedBims(address account) public view returns(uint256) {
        uint256 monthAgo = block.timestamp - MONTH;
        uint256 lockedAmount;
        for (int256 i= currentRound; i>=0; i--) {
            if (rounds[i].startDate < monthAgo) {
                break;
            } else {
                lockedAmount += rounds[i].balances[account];
            }
        }
        
        return lockedAmount;
    }

    /**
     * @dev check current claimable BIMS without penalty
     */
    function checkUnlockedBims(address account) public view returns(uint256) {
        uint256 lockedAmount = checkLockedBims(account);
        return balances[account].sub(lockedAmount);
    }
    
    /**
     * @dev claim unlocked BIMS without penalty
     */
    function claimUnlockedBims() external {
        update();
        
        uint256 unlockedAmount = checkUnlockedBims(msg.sender);
        balances[msg.sender] -= unlockedAmount;
        BIMContract.safeTransfer(msg.sender, unlockedAmount);
        
        emit Claimed(msg.sender, unlockedAmount);
    }

    /**
     * @dev claim all BIMS with penalty
     */
    function claimAllBims() external {
        update();
        
        uint256 lockedAmount = checkLockedBims(msg.sender);
        uint256 penalty = lockedAmount/2;
        uint256 bimsToClaim = balances[msg.sender].sub(penalty);

        // reset balances in this month(still locked) to 0
        uint256 monthAgo = block.timestamp - MONTH;
        for (int256 i= currentRound; i>=0; i--) {
            if (rounds[i].startDate < monthAgo) {
                break;
            } else {
                delete rounds[i].balances[msg.sender];
            }
        }
        
        // reset user's total balance to 0
        delete balances[msg.sender];
        
        // transfer BIMS to msg.sender        
        if (bimsToClaim > 0) {
            BIMContract.safeTransfer(msg.sender, bimsToClaim);
            emit Claimed(msg.sender, bimsToClaim);
        }
        
        // 50% penalty BIM goes to BIMLockup contract
        if (penalty > 0) {
            BIMContract.safeTransfer(address(BIMLockupContract), penalty);
            emit Penalty(msg.sender, penalty);
        }
    }
    
    /**
     * @dev round update operation
     */
    function update() public {
        uint numDays = block.timestamp.sub(rounds[currentRound].startDate).div(DAY);
        if (numDays > 0) {
            currentRound++;
            rounds[currentRound].startDate = rounds[currentRound-1].startDate + numDays * DAY;
        }
    }
    
    /**
     * @dev Events
     * ----------------------------------------------------------------------------------
     */
     
    event Vestable(address account);
    event Unvestable(address account);
    event Penalty(address account, uint256 amount);
    event Vested(address account, uint256 amount);
    event Claimed(address account, uint256 amount);
    
}