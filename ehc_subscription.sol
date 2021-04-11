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

contract EHCSubscription is Ownable {
    using SafeMath for uint;
    using SafeERC20 for IEHCToken;
    using SafeERC20 for IERC20;

    uint256 constant DAY = 10;
    uint256 constant WEEK = DAY * 7;
    uint256 constant MONTH = DAY * 30;
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow
    uint256 internal constant PRICE_UNIT = 1e18; // PRICE_UNIT for 1 EHC

    IEHCToken public EHCToken;
    IERC20 public USDTContract;
    IEHCOralce public EHCOracle;
    
    // @dev subscription are grouped by week
    struct Round {
        // fields set at new round
        uint256 mintCap; // maximum supply of EHC in this round
        uint256 price; // price for subscription. NOTE: the price is for 1 EHC
        uint startTime; // startTime for this round

        // fields set during subscription period
        mapping (address => uint256) balances; // USDTS
        uint256 totalUSDTS; // sum of balances

        // fields set after subscription settlement
        bool subEnded; // mark if subscription ends
        uint256 refundPerUSDT; // USDTS to refund for over subscription
        uint256 ehcPerUSDTSecs; // EHC per USDTS per seconds

        mapping (address => uint256) lastClaim;  // EHC last claim() date
        mapping (address => bool) refundClaimed; // USDT refunded mark
    }
    
    /// @dev rounds indexing
    mapping (int256 => Round) public rounds;
    /// @dev a monotonic increasing index, starts from 1
    int256 public currentRound = 1;

    /// @dev settled USDT refund balance
    mapping (address => uint256) internal _refundBalance; 
    
    /// @dev settled EHC balance
    mapping (address => uint256) internal _ehcBalance; 
    
    /// @dev a struct to keep at most 2 round index for a user
    struct RoundIndex {
        int256 prev;
        int256 lastest;
    }
    
    /// @dev user's recent subscribed 2 rounds
    mapping (address => RoundIndex) internal _roundIndices;  

    /// @dev contract confirmed USDTS
    uint256 public confirmedUSDTs;
    
    constructor(IEHCToken ehcToken, IERC20 usdtContract, IEHCOralce oracle) public {
        EHCToken = ehcToken;
        USDTContract = usdtContract;
        EHCOracle = oracle;
        
        // setting round 0 
        rounds[currentRound].startTime = block.timestamp;
        rounds[currentRound].price = EHCOracle.getPrice();
        rounds[currentRound].mintCap = EHCToken.totalSupply().mul(25).div(100);
    }
    
    /**
     * @dev deposit USDT to receive EHC
     */
    function subscribe(int256 r, uint256 amountUSDT) external returns(bool) {
        update();
        
        // make sure round is currentRound
        require (currentRound == r, "round expired");
        // make sure we are still in subscription period
        Round storage round = rounds[r];
        require (!round.subEnded, "subscription ended");
        
        // transfer USDT to this round
        USDTContract.safeTransferFrom(msg.sender, address(this), amountUSDT);
        round.balances[msg.sender] += amountUSDT;
        round.totalUSDTS += amountUSDT;
        
        // try to settle previously unclaimed EHC
        RoundIndex storage idx = _roundIndices[msg.sender];
        if (idx.lastest != currentRound) {
            // release previous EHC to balance
            settleRound(msg.sender, idx.prev);
            
            // make a shifting, by always keep idx.lastest to current round
            //
            // [prev, latest] <- currentRound 
            // ----> prev [lastest, currentRound]
            // 
            // 'prev' poped out (EHC already all released).
            idx.prev = idx.lastest;
            idx.lastest = currentRound;
        }
        
        return true;
    }
    
    /**
     * @dev owner claim confirmed USDTs
     */
    function claimConfirmedUSDT() external onlyOwner {
        uint256 confirmed = confirmedUSDTs;
        // extra check for possible rounding problem
        if (USDTContract.balanceOf(owner()) < confirmed) {
            confirmed = USDTContract.balanceOf(owner());
        }
        
        // transfer confirmed amount
        USDTContract.safeTransfer(owner(), confirmed);
        confirmedUSDTs -= confirmed;
    }
    
    /**
     * @dev claim EHC
     */
    function claimEHC() external {
        update();
        
        RoundIndex storage idx = _roundIndices[msg.sender];
        
        // settle possible previous subscribed EHC
        settleRound(msg.sender, idx.lastest);
        settleRound(msg.sender, idx.prev);
        
        // clear balance
        uint256 amount = _ehcBalance[msg.sender];
        delete _ehcBalance[msg.sender];
        
        // send back
        EHCToken.safeTransfer(msg.sender, amount);
    }
    
    /**
     * @dev claim refund
     */
    function claimRefund() external {
        update();
        
        RoundIndex storage idx = _roundIndices[msg.sender];
            
        // settle possible previous refundable rounds
        settleRound(msg.sender, idx.lastest);
        settleRound(msg.sender, idx.prev);
        
        // clear balance
        uint256 amount = _refundBalance[msg.sender];
        delete _refundBalance[msg.sender];
        
        // send back
        USDTContract.safeTransfer(msg.sender, amount);
    }
        
    /**
     * @dev 
     * 1. try release any EHC on round r based on timestamp
     * 2. settle refund USDTS
     */
    function settleRound(address account, int256 r) internal {
        Round storage round = rounds[r];
        if (round.subEnded) {
            // EHC settlement
            uint256 ehc = checkRoundEHC(account, r);
            _ehcBalance[account] += ehc;
            round.lastClaim[account] = block.timestamp;
            
            // refund settlement
            uint256 refund = checkRoundRefund(account,r);
            _refundBalance[account] += refund;
            round.refundClaimed[account] = true;
        }
    }
    
    /**
     * @dev update function for round control
     */
    function update() public {
        // check subscription ends and need settlement
        Round storage round = rounds[currentRound];
        if (block.timestamp > round.startTime + WEEK && !round.subEnded) {
            // maximum USDTs
            uint256 capUSDTS = round.mintCap.mul(round.price)
                                            .div(PRICE_UNIT);
            
            uint256 ehcToMint;
            
            // over subscribed, set refundPerUSDT
            if (round.totalUSDTS > capUSDTS) {
                // set to: (totalUSDT - capUSDT) / totalUSDT
                round.refundPerUSDT = round.totalUSDTS.sub(capUSDTS)
                                                        .mul(SHARE_MULTIPLIER)  // NOTE: refund share has multiplied by SHARE_MULTIPLIER
                                                        .div(round.totalUSDTS);
                
                // set ehc to mint to maximum                                             
                ehcToMint = round.mintCap;

                // record USDT earned to capUSDTS;
                confirmedUSDTs += capUSDTS;
            } else {
                // set ehc to mint by total USDT
                ehcToMint = round.totalUSDTS.mul(PRICE_UNIT)
                                            .div(round.price);
                
                // record USDT earned to total received
                confirmedUSDTs += round.totalUSDTS;
            }
            
            // check 0 subscription before setting share
            if (round.totalUSDTS > 0) {
                // set EHC share per totalUSDTS per seconds
                round.ehcPerUSDTSecs = ehcToMint.mul(SHARE_MULTIPLIER) // NOTE: ehcPerUSDTSecs has multiplied by SHARE_MULTIPLIER
                                                .div(round.totalUSDTS)
                                                .div(MONTH);
                
                // mint EHC to this contract
                EHCToken.mint(address(this), ehcToMint);
            }
            
            // mark subscription ends
            round.subEnded = true;
            
        } else if (block.timestamp > round.startTime + MONTH) { // new round initiate
            currentRound++;
            
            // set new round parameters
            rounds[currentRound].startTime = rounds[currentRound-1].startTime + MONTH;
            rounds[currentRound].price = EHCOracle.getPrice();
            rounds[currentRound].mintCap = EHCToken.totalSupply().mul(25).div(100);
        }
    }
    
    
    /**
     * @dev VIEW functions
     */
     
    /**
     * @dev check unlocked EHC
     */
    function checkUnlockedEHC(address account) external view returns (uint256 amount) {
        RoundIndex storage idx = _roundIndices[msg.sender];
        amount += checkRoundEHC(account, idx.prev);
        amount += checkRoundEHC(account, idx.lastest);
        amount += _ehcBalance[account];
    }
    
    /**
     * @dev check refund
     */
    function checkRefund(address account) external view returns (uint256 amount) {
        RoundIndex storage idx = _roundIndices[msg.sender];
        amount += checkRoundRefund(account, idx.prev);
        amount += checkRoundRefund(account, idx.lastest);
        amount += _refundBalance[account];
    }
        /**
     * @dev check existing refund on round r 
     */
    function checkRoundRefund(address account, int256 r) internal view returns(uint256 refund) {
        Round storage round = rounds[r];
        // refund USDT
        if (!round.refundClaimed[account] && round.refundPerUSDT > 0) {
            return round.refundPerUSDT.mul(round.balances[account])
                                        .div(SHARE_MULTIPLIER);
        }
    }
    
    /**
     * @dev check unlocked EHC on round r bsed on timestamp
     */
    function checkRoundEHC(address account, int256 r) internal view returns(uint256 release) {
        Round storage round = rounds[r];
        if (block.timestamp > round.startTime + WEEK) {
            // if block.timestamp has passed one WEEK+MONTH since round.startTime
            // we cap it to the last second
            uint timestamp = block.timestamp;
            if (timestamp > round.startTime.add(WEEK).add(MONTH)) {
                timestamp = round.startTime.add(WEEK).add(MONTH);
            }

            // compute time passed since last claim
            // [startTime -- WEEK -- release start(settled) -- 30 days --- release end]
            uint lastClaim = round.lastClaim[account] == 0? // never claimed
                                    round.startTime.add(WEEK):round.lastClaim[account];

            // convert time elapsed -> EHC token
            if (timestamp > lastClaim) {
                uint duration = timestamp.sub(lastClaim);
                
                return duration.mul(round.ehcPerUSDTSecs)
                                .mul(round.balances[account])
                                .div(SHARE_MULTIPLIER);
            }
        }
    }
    
    /**
     * @dev check round subscriptions
     */
    function checkRoundSubscription(address account, int256 r) external view returns(uint256) {
        return rounds[r].balances[account];
    }
}