// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "./yearn/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "./openzeppelin/SafeERC20.sol";
import {Math} from "./openzeppelin/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

interface IChainlinkFeed {
    function latestAnswer() external view returns (uint256);
}

interface IRewards {
    function claimable(address) external view returns (uint256);
    function claim() external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256) external returns(uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns(uint256);
}

interface ILooksRareFee {
    function calculatePendingRewards(address) external view returns (uint256);
    function calculateSharesValueInLOOKS(address) external view returns (uint256);
    function deposit(uint256, bool) external;
    function harvest() external;
    function withdraw(uint256, bool) external;
    function withdrawAll(bool) external;
    function userInfo(address) external view returns(uint256, uint256, uint256);
    function calculateSharePriceInLOOKS() external view returns(uint256);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}



// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    //staking contract
    address public constant LooksRareStaking = 0xBcD7254A1D759EFA08eC7c3291B2E85c5dCC12ce;

    //$LOOKS token
    IERC20 public constant LOOKSToken = IERC20(0xf4d2888d29D722226FafA5d9B24F9164c092421E);

    //$WETH as I don't think we get actual ETH
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    //hard code univ2 router
    IUniswapV2Router02 public constant univ2router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    //hard code staking contract
    ILooksRareFee public constant looksRareContract = ILooksRareFee(0xBcD7254A1D759EFA08eC7c3291B2E85c5dCC12ce);

    //max for 256-1 on approve
    uint256 public constant max = type(uint256).max;

    //Base amount for floor $LOOKS token
    uint256 private constant base = 1e18;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        firstTimeApprovals();
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyLooksRareFeeShare";
    }

    function _pendingRewards() internal view returns(uint256 wethEstimate) {
        wethEstimate = looksRareContract.calculatePendingRewards(address(this));
    }

    function _stakedAmount() public view returns(uint256 currentShareValue){
        currentShareValue = looksRareContract.calculateSharesValueInLOOKS(address(this));
    }

    function _sharePrice() internal view returns(uint256 sharePrice){
       sharePrice = looksRareContract.calculateSharePriceInLOOKS();
    }

    function balanceOfWant() public view returns (uint256){
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // First look at the LOOKS staking shares we have and call the contract for its value in LOOKS token
        uint256 currentShareValue = _stakedAmount();
        
        //Return total
        return balanceOfWant().add(currentShareValue);
    }

    function withdrawProfitOrFloor(uint profit) internal {
        //Ensure we're not going to attempt to sub from unneeded balance
        uint256 amount = 0;
        if(profit > balanceOfWant()){
            amount = profit.sub(balanceOfWant());
        }
        //Check that our staked amount is greater than 1 token which is min
        //This way we do not attempt to withdraw 0 (which reverts)
        if(_stakedAmount() >= base){
            //Withdraw the larger of the needed amount or of the base number.
            //In the case where we only need 0.5 LOOKS to meet our balance obligations we round up to 1 LOOKS to meet the withdraw floor.
            looksRareContract.withdraw(Math.max(amount,base),false);
        }
    }

event vaultDebtEvent(uint256 _amount);
event wethEstimateEvent(uint256 _amount);
event swapAmountEvent(uint256 _amount);
event prepareReturnSharesValueEvent(uint256 _amount);
event LOOKSProfitEvent(uint256 _amount);
event finalProfitEvent(uint256 _amount);
event debtOutstandingEvent(uint256 _amount);
event withdrawPreReportEvent(uint256 _amount);

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        //grab the estimate total debt from the vault
        uint256 vaultDebt = vault.strategies(address(this)).totalDebt;
        emit vaultDebtEvent(vaultDebt);

        uint256 LOOKSprofit = 0;
        
        //Estimate any pending weth rewards
        uint256 wethEstimate = _pendingRewards();
        emit wethEstimateEvent(wethEstimate);

        uint swapAmount = 0;

        //Harvest rewards (weth) from the pool if greater than zero.
        if(wethEstimate > 0){
            looksRareContract.harvest();
            swapAmount = _sellRewards();
        }

        //calculate the amount of LOOKS we need, cannot be less than 1 due to contract restrictions.
        if(_debtOutstanding <= 1e18 && balanceOfWant() < _debtOutstanding){
            uint256 sharePrice = _sharePrice();
            uint256 withdrawPreReport = _debtOutstanding.mul(10 ** IDecimals(address(want)).decimals()).div(sharePrice);
            //Withdraw any extra needed LOOKS > 1. Do not claim rewards as they were already claimed so we can save gas here.
            looksRareContract.withdraw(withdrawPreReport,false);
        }

        //Get current total LOOKS value of our share position
        uint256 currentShareValue = _stakedAmount();
        emit prepareReturnSharesValueEvent(currentShareValue);

        //calculate the total holdings in LOOKS
        LOOKSprofit = currentShareValue.add(balanceOfWant());
        
        //Calculate final profit as delta between our LOOKSprofit and the total vault debt. Should be impossible for it to be a loss unless pool is drained.
        uint256 finalProfit = LOOKSprofit.sub(vaultDebt);

        emit finalProfitEvent(finalProfit);

        //Invoke funciton to withdraw the difference between profit and gain in the LOOKS token
        //This is because in Yearn Vaults line #1746 enforces a check that the balance must be greater than gain + debtpayment
        //We must calculate the growth in staked LOOKS otherwise it isn't ever going to get claimed, and we must withdraw it to pass this revert check.
        withdrawProfitOrFloor(finalProfit);

        //If there is no debt outstanding, deposit all looks back into contract and report back profit
        emit debtOutstandingEvent(_debtOutstanding);
        if(finalProfit < _debtOutstanding){
            _profit = 0;
            _debtPayment = balanceOfWant();
            _loss = _debtOutstanding.sub(_debtPayment);
        } else {
            _profit = finalProfit.sub(_debtOutstanding);
            _debtPayment = _debtOutstanding;
        }
    }
    
event toDepositEvent(uint256 _amount);
event toDepositFloorEvent(uint256 _amount);
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        //no need for us to use debt as we can always pull it out. This is just here to silence warnings in compiler of unused var.
        uint256 debt = _debtOutstanding;

        //Figure out how much can be deposited
        uint256 toDeposit = want.balanceOf(address(this));
        emit toDepositEvent(toDeposit);

        //set deposit floor as the looks contract doesn't allow staking below 1 LOOKS
        uint256 depositFloor = 1 * 10 ** 18;
        emit toDepositFloorEvent(depositFloor);

        //Deposit without claim as we'll claim rewards only on a prepare to better track.
        if(toDeposit > depositFloor){
            looksRareContract.deposit(toDeposit,false);
        }
    }

    function firstTimeApprovals() internal {
        //check if tokens are approved as needed.
        if(LOOKSToken.allowance(address(this),LooksRareStaking) == 0){
            LOOKSToken.approve(LooksRareStaking, max);
        }
        if(LOOKSToken.allowance(address(this),address(univ2router)) == 0){
            LOOKSToken.approve(address(univ2router), max);
        }
        if(WETH.allowance(address(this),address(univ2router)) == 0){
            WETH.approve(address(univ2router), max);
        }

    }

event amountNeededEvent(uint256 _amount);
event liveShareValueEvent(uint256 _amount);
event sharesOwnedEvent(uint256 _amount);
event sharedNeededEvent(uint256 _amount);
event sharePriceCompareEvent(uint256 _amount);
event postWithdrawBalanceEvent(uint256 _amount);

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        emit amountNeededEvent(_amountNeeded);
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        //Sanitycheck that amount needed is not 0
        if(_amountNeeded > 0){
            uint256 unusedBalance = balanceOfWant();

            if(unusedBalance < _amountNeeded){
                //Get the current amount of our entire share position expressed in LOOKS
                uint256 liveShareValue = _stakedAmount();

                //Get the current share price expressed in LOOKS
                uint256 generalSharePrice = _sharePrice();
                emit sharePriceCompareEvent(generalSharePrice);
                emit liveShareValueEvent(liveShareValue);

                //Get the amount of shares that the strategy holds in total.
                (uint256 shares, , ) = looksRareContract.userInfo(address(this));
                emit sharesOwnedEvent(shares);

                //Calculate how many shares we need to cash out to get enough LOOKS to cover _amountNeeded.
                uint256 sharesNeeded = (_amountNeeded.sub(unusedBalance)).mul(1e18).div(generalSharePrice);
                emit sharedNeededEvent(sharesNeeded);

                //Check if we have enough shares total.
                if(sharesNeeded <= shares){
                    //if we have enough shares, then withdraw only the specific share amount needed.
                    looksRareContract.withdraw(sharesNeeded,false);
                } else {
                    //if we do not have enough shares then we should withdraw all shares, however, we should not claim WETH rewards as converting them here would not be captured under profit.
                    looksRareContract.withdrawAll(false);
                }
            }
        }

        //We now check the total assets amount we have post withdraw.
        uint256 totalAssets = balanceOfWant();
        emit postWithdrawBalanceEvent(totalAssets);

        //If the amount we need is more than the total amount of assets we have.
        if (_amountNeeded > totalAssets) {
            //report liquidated emount is the total amount of assets
            _liquidatedAmount = totalAssets;
            //report the delta as a loss
            _loss = _amountNeeded.sub(totalAssets);
            return(_liquidatedAmount, _loss);
        } else {
            //otherwise the liquidated amount is the amount needed and we have no loss.
            _liquidatedAmount = _amountNeeded;
            return(_liquidatedAmount,0);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.

        //We then withdraw with claim to get the full balance including the latest rewards
        looksRareContract.withdrawAll(true);

        //We do a check to see if we have any WETH from the last rewards set that isn't converted.
        uint256 wethCheck = IERC20(WETH).balanceOf(address(this));

        //If the WETH balance is non-zero we'll initiate a swap.
        if(wethCheck != 0){
            _sellRewards();
        }
        
        //Now that all possible rewards are fully in LOOKS and in this address, we return the balance expressed in LOOKS
        return want.balanceOf(address(this));
    }


    function _sellRewards() internal returns(uint256){
            uint256 swapAmount;
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(LOOKSToken);
            uint256 expTime = block.timestamp + 3600;
            uint256[] memory returnedAmounts = univ2router.swapExactTokensForTokens(IERC20(WETH).balanceOf(address(this)),0,path,address(this),expTime);
            swapAmount = returnedAmounts[1];
            emit swapAmountEvent(swapAmount);
            return swapAmount;
    }
    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        liquidateAllPositions();
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }
}