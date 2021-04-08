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

    uint256 constant DAY = 86400;
    uint256 constant MONTH = DAY * 30;
    
    IBIMToken public BIMContract;
    IERC20 public BIMLockupContract;

    /**
     * @dev Emitted when an account is set vestable
     */
    event Vestable(address account);
    /**
     * @dev Emitted when an account is set unvestable
     */
    event Unvestable(address account);

    // @dev vestable group
    mapping(address => bool) public vestableGroup;
    
    modifier onlyVestableGroup() {
        require(vestableGroup[msg.sender], "not in vestable group");
        _;
    }
    
    // @dev vesting assets are grouped by duration
    struct Round {
        mapping (address => uint256) balances;
        uint startDate;
    }
    
    /// @dev round index mapping week data
    mapping (uint => Round) public rounds;
    /// @dev a monotonic increasing index, starts from 1 to avoid underflow
    uint256 public currentRound = 1;

    /// @dev curent locked BIMS    
    mapping (address => uint256)public  balances;

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
     * 1. LPStaking
     * 2. EHCStaking
     */
    function vest(address account, uint256 amount) external override onlyVestableGroup {
        update();

        rounds[currentRound].balances[account] += amount;
        balances[account] += amount;
    }

    /**
     * @dev check current claimable BIMS without penalty
     */
    function checkUnlockedBims(address account) public view returns(uint256) {
        uint256 monthAgo = block.timestamp - MONTH;
        uint256 lockedAmount;
        for (uint i= currentRound; i>0; i--) {
            if (rounds[i].startDate < monthAgo) {
                return balances[account].sub(lockedAmount);
            } else {
                lockedAmount += rounds[i].balances[account];
            }
        }
    }
    
    /**
     * @dev claim BIMS without penalty
     */
    function claimUnlockedBims() external {
        update();
        uint256 unlockedAmount = checkUnlockedBims(msg.sender);
        balances[msg.sender] -= unlockedAmount;
        BIMContract.safeTransfer(msg.sender, unlockedAmount);
    }

    /**
     * @dev claim BIMS with penalty possibility
     */
    function claimAllBims() external {
        update();
        
        uint256 unlockedAmount = checkUnlockedBims(msg.sender);
        uint256 lockedAmount = balances[msg.sender].sub(unlockedAmount);
        uint256 penalty = lockedAmount/2;
        uint256 clearBIMS = balances[msg.sender].sub(penalty);
        
        if (clearBIMS > 0) {
            BIMContract.safeTransfer(msg.sender, clearBIMS);
        }
        
        // 50% penalty BIM goes to MonthBIMContract
        if (penalty > 0) {
            BIMContract.safeTransfer(address(BIMLockupContract), penalty);
        }
        
        delete balances[msg.sender];
    }
    
    /**
     * @dev update operation
     */
    function update() internal {
        if (block.timestamp.sub(rounds[currentRound].startDate) >= DAY) {
            currentRound++;
            rounds[currentRound].startDate = rounds[currentRound-1].startDate + DAY;
        }
    }
}