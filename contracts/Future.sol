// SPDX-License-Identifier: MIT
pragma solidity 0.6.9;

/* TODO:
    1. Fee
    2. SafeDecimalMath
*/

/*
import "github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/contracts/math/SafeMath.sol";
import "github.com/OpenZeppelin/openzeppelin-contracts/contracts/math/Math.sol";
*/

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./IExpandedERC20.sol";

contract Future {
    using Math for uint256;
    using SafeMath for uint256;

    uint256 public constant UNIT = 10**uint256(18);

    address public backedToken;                     // Settlement asset
    address public longToken;                       // Base asset
    address public shortToken;                      // Quote asset (synthetic USD)
    
    uint256 totalLongDeposit;                       // D_1 in asset
    uint256 totalLongDepositInUSD;                  // D_1 in USD

    mapping(address => uint256) longDeposits;
    mapping(address => uint256) shortDeposits;
    
    mapping(address => uint256) longProfit;
    mapping(address => uint256) shortProfit;

    uint256 latestRate;                             // Asset / USD
    uint256 divergenceRate;                         // r
    
    // Total number of long positions ever created
    uint256 public totalLongCreated;
    
    // Total number of positions ever created
    uint256 public totalPositionCreated;

    // Total number of open long positions
    uint256 public totalOpenLongCount;

    // Total number of open short positions
    uint256 public totalOpenShortCount;

    // Synth loan storage struct
    struct FutureContract {
        // ID for the future contract
        uint256 futureID;
        // Rate at the moment
        uint256 initialRate;
        // Amount that they deposited 
        uint256 initialMargin;
        // Amount (in synths) that they received
        uint256 initialPosition;
        // Amount (in synths) that they still hold
        uint256 position;
        // When the loan was created
        uint256 timeCreated;
        // When the loan was paidback (closed)
        uint256 timeClosed;
    }
    
    mapping(address => FutureContract[]) longs;
    mapping(address => FutureContract[]) shorts;

    // ----------------------- CONSTRUCTOR --------------------------
    
    constructor(
        address _backedToken
    ) public {
        backedToken = _backedToken;
    }

    // ------------------------- GETTER -----------------------------
    
    function longRateInAsset() public view returns (uint256 rate) {
        rate = UNIT.mul(totalLongDeposit).div(IERC20(longToken).totalSupply());
    }
    
    function longRate() public view returns (uint256 rate) {
        rate = UNIT.mul(totalLongDepositInUSD).div(IERC20(longToken).totalSupply());
    }

    function shortRate() public view returns (uint256 rate) {
        uint256 totalShortDeposit = IERC20(backedToken).totalSupply().sub(totalLongDeposit);
        rate = UNIT.mul(totalShortDeposit).div(IERC20(shortToken).totalSupply());
    }
    
    function unrealizedPNL(address account) public view returns (
        uint256 unrealizedLongProfit,
        uint256 unrealizedLongLoss,
        uint256 unrealizedShortProfit,
        uint256 unrealizedShortLoss
    ) {
        uint256 position;
        uint256 initialRate;

        uint256 lRate = longRateInAsset();
        uint256 sRate = shortRate();

        for (uint256 i = 0; i < longs[account].length; i++) {
            position = longs[account][i].position;
            initialRate = longs[account][i].initialRate;

            uint256 currentValue = position * lRate / UNIT;
            uint256 initialValue = position * initialRate / UNIT;

            if (currentValue >= initialValue) {
                unrealizedLongProfit = currentValue - initialValue + unrealizedLongProfit;
            } else {
                unrealizedLongLoss = initialValue - currentValue + unrealizedLongLoss;
            }
        }

        for (uint256 i = 0; i < shorts[account].length; i++) {
            position = shorts[account][i].position;
            initialRate = shorts[account][i].initialRate;

            uint256 currentValue = position * sRate / UNIT;
            uint256 initialValue = position * UNIT / initialRate;

            if (currentValue >= initialValue) {
                unrealizedShortProfit = currentValue - initialValue + unrealizedShortProfit;
            } else {
                unrealizedShortLoss = initialValue - currentValue + unrealizedShortLoss;
            }
        }
    }
    
    // ------------------------- SETTER -----------------------------
    
    function updateRate(uint256 value) public {
        latestRate = value;
    }
    
    // -------------------- MUTATIVE FUNCTIONS ----------------------

    function openLong(uint256 initialMargin /*in Asset*/) public {
        // Calculate initial funds and position
        // Mote that currently there is no leverage, so inital margin equals to the position
        uint256 initialFunds = initialMargin;
        uint256 initialPosition = initialFunds;

        totalLongDepositInUSD = totalLongDepositInUSD + initialFunds * latestRate / UNIT;
        
        // D_1 + x = D_1'
        longDeposits[msg.sender] = longDeposits[msg.sender] + initialFunds;
        totalLongDeposit = totalLongDeposit + initialFunds;

        // S_1 + x * P_0 = S_1'
        IExpandedERC20(longToken).mint(msg.sender, initialPosition);
        
        // Get the global future id, incrementing the counter
        uint256 futureID = _incrementTotalPositionCounter(true);
        
        // Record the position into the ledger
        _recordCreation(futureID, initialPosition, initialMargin, true);
    }
    
    function openShort(uint256 initialMargin /*in Asset*/) public {
        // Calculate initial funds and position
        // Mote that currently there is no leverage, so position equals to inital margin
        uint256 initialFunds = initialMargin;
        uint256 initialPosition = initialFunds * latestRate / UNIT;

        // D_2 + x = D_2'
        shortDeposits[msg.sender] = shortDeposits[msg.sender] + initialFunds;

        // S_2 + x / P_0 = S_2'
        IExpandedERC20(shortToken).mint(msg.sender, initialPosition);
        
        // Get the global future id, incrementing the counter
        uint256 futureID = _incrementTotalPositionCounter(false);
        
        // Record the position into the ledger
        _recordCreation(futureID, initialPosition, initialMargin, false);
    }
    
    function closeLong(uint256 position /*in sAsset*/) public {
        // S_1 - y = S_1'
        IExpandedERC20(longToken).burn(msg.sender, position);

        // D_1 - y * (D_1 / S_1) = D_1'
        uint256 lRate = longRateInAsset();
        uint256 profit = position * lRate / UNIT;
        
        longProfit[msg.sender] = longProfit[msg.sender] + profit;
        totalLongDeposit = totalLongDeposit - profit;
        IERC20(backedToken).transfer(msg.sender, profit);

        _recordClosure(position, true);
    }
    
    function closeShort(uint256 position /*in iAsset/sUSD*/) public {
        // S_2 - y = S_2'
        IExpandedERC20(shortToken).burn(msg.sender, position);

        // D_2 - y * (D_2 / S_2) = D_2'
        uint256 sRate = shortRate();
        uint256 profit = position * sRate / UNIT;
        
        shortProfit[msg.sender] = shortProfit[msg.sender] + profit;
        IERC20(backedToken).transfer(msg.sender, profit);

        _recordClosure(position, false);
    }
    
    function remargin() public {
        uint256 targetTotalShortDeposit = IERC20(shortToken).totalSupply() * UNIT / latestRate;
        uint256 totalShortDeposit = IERC20(backedToken).totalSupply() - totalLongDeposit;
        
        // P_inverse = P = (D_2 + d) / S_2
        //
        // Rebalance the deposit distribution to keep short contract price as close to the market price as possible:
        // Note that if d is positive, make sure that the long contract price does not fall out of a rational range
        if (targetTotalShortDeposit > totalShortDeposit) {
            uint256 issuredTotalLongDeposit = IERC20(longToken).totalSupply() * totalLongDeposit * latestRate / (divergenceRate * totalLongDepositInUSD * UNIT);
            
            // d = max(PS_2 - D_2, D_1 - S_1 / rP)
            uint256 d = Math.max(
                targetTotalShortDeposit - totalShortDeposit,
                totalLongDeposit - issuredTotalLongDeposit);
            
            totalLongDepositInUSD = totalLongDepositInUSD * (totalLongDeposit - d) / totalLongDeposit;
            totalLongDeposit = totalLongDeposit - d;
        } else if (targetTotalShortDeposit < totalShortDeposit) {
            uint256 d = totalShortDeposit - targetTotalShortDeposit;
            
            totalLongDepositInUSD = totalLongDepositInUSD * (totalLongDeposit + d) / totalLongDeposit;
            totalLongDeposit = totalLongDeposit + d;
        }
    }

    // ------------------------- HELPER -----------------------------

    function _incrementTotalPositionCounter(bool isLong) internal returns (uint256) {
        if (isLong) {
            // Increase the total Open long count
            totalOpenLongCount = totalOpenLongCount.add(1);
            // Increase the total long created count
            totalLongCreated = totalLongCreated.add(1);
        } else {
            // Increase the total Open long count
            totalOpenShortCount = totalOpenShortCount.add(1);
        }

        // Increase the total future created count
        totalPositionCreated = totalPositionCreated.add(1);
        
        // Return total count to be used as a unique ID.
        return totalPositionCreated;
    }
    
    function _recordCreation(uint256 futureID, uint256 initialPosition, uint256 initialMargin, bool isLong) internal {
        // Create Future storage object
        FutureContract memory future = FutureContract({
            futureID: futureID,
            initialRate: latestRate,
            initialMargin: initialMargin,
            initialPosition: initialPosition,
            position: initialPosition,
            timeCreated: now,
            timeClosed: 0
        });

        // Record loan in mapping to account in a priority queue of the accounts open positions
        if (isLong) {
            for (uint i = 0; i < longs[msg.sender].length; i++) {
                if (longs[msg.sender][i].initialRate > latestRate) {
                    // TODO: insert in the middle
                    longs[msg.sender].push(future);
                    break;
                }
            }

            //longs[msg.sender].push(future);
        } else {
            for (uint i = 0; i < longs[msg.sender].length; i++) {
                if (longs[msg.sender][i].initialRate < latestRate) {
                    longs[msg.sender].push(future);
                    break;
                }
            }

            //shorts[msg.sender].push(future);
        }
    }

    function _recordClosure(uint256 position, bool isLong) internal returns (uint256) {
        uint256 positionToBeClosed = position;
        uint i = 0;

        // Record loan in mapping to account in an array of the accounts open loans
        if (isLong) {
            for (; i < longs[msg.sender].length && positionToBeClosed > 0; i++) {
                if (longs[msg.sender][i].timeClosed != 0) {
                    if (longs[msg.sender][i].position > positionToBeClosed) {
                        longs[msg.sender][i].position = longs[msg.sender][i].position - position;
                        positionToBeClosed = 0;
                    } else {
                        longs[msg.sender][i].position = 0;
                        longs[msg.sender][i].timeClosed = now;

                        positionToBeClosed = positionToBeClosed - longs[msg.sender][i].position;
                    }
                }
            }
        } else {
            for (; i < shorts[msg.sender].length && positionToBeClosed > 0; i++) {
                if (shorts[msg.sender][i].timeClosed != 0) {
                    if (shorts[msg.sender][i].position > positionToBeClosed) {
                        shorts[msg.sender][i].position = shorts[msg.sender][i].position - position;
                        positionToBeClosed = 0;
                    } else {
                        shorts[msg.sender][i].position = 0;
                        shorts[msg.sender][i].timeClosed = now;

                        positionToBeClosed = positionToBeClosed - shorts[msg.sender][i].position;
                    }
                }
            }
        }
    }
}