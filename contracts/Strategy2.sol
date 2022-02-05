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



// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    bool public paused;

    //staking contract
    address public LooksRareStaking = 0xBcD7254A1D759EFA08eC7c3291B2E85c5dCC12ce;

    //$LOOKS token
    address public LOOKSToken = 0xf4d2888d29D722226FafA5d9B24F9164c092421E;

    //$WETH as I don't think we get actual ETH
    address public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    //declare multisig for control - not sure if this is inhereted already
    address public multisig;

    //hard code univ2 router
    address public univ2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    //Hash for 256-1 on approve
    uint256 public hash = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    //We earn WETH but we also gain additional pending LOOKS, we need a way to figure out how much of that is deposited versus profit, so we take snapshots.
    uint256 public lastSnapshotBlock;
    uint256 public LooksLastSnapshotAmount;
    uint256 public depositedSinceLastSnapshot;
    uint256 public withdrawnSinceLastSnapshot;
    uint256 public lastSwapAmount;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyLooksRareFeeShare";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // First look at the LOOKS staking shares we have and call the contract for its value in LOOKS token
        uint256 currentShareValue = ILooksRareFee(LooksRareStaking).calculateSharesValueInLOOKS(address(this));

        //Check the amount of pending WETH rewards we have as well.
        uint256 currentPendingWeth = ILooksRareFee(LooksRareStaking).calculatePendingRewards(address(this));
        uint256 expectedReturn = 0;

        if(currentPendingWeth != 0){
            //Create path for Univ2 router to estimate the conversion rate of WETH to LOOKS
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(LOOKSToken);

            //Query to get exchange rate
            expectedReturn = IUniswapV2Router02(univ2Router).getAmountsOut(currentPendingWeth, path);
        }

        //Add exchange rate to current share value.
        uint256 convertedBalance = currentShareValue + expectedReturn;
        
        //Return total
        return want.balanceOf(address(this)).add(convertedBalance);
    }

event vaultDebtEvent(uint256 _amount);
event wethEstimateEvent(uint256 _amount);
event swapAmountEvent(uint256 _amount);
event prepareReturnSharesValueEvent(uint256 _amount);
event LOOKSProfitEvent(uint256 _amount);
event finalProfitEvent(uint256 _amount);
event debtOutstandingEvent(uint256 _amount);
event balanceCheckEvent(uint256 _amount);
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
        //uint profit;
        uint256 vaultDebt = vault.strategies(address(this)).totalDebt;
        emit vaultDebtEvent(vaultDebt);

        uint256 LOOKSprofit = 0;
        
        //To prevent error, only subtract previous snapshots if value already exists
        
        uint256 wethEstimate = ILooksRareFee(LooksRareStaking).calculatePendingRewards(address(this));
        emit wethEstimateEvent(wethEstimate);
        uint swapAmount = 0;
        //Harvest rewards (weth) from the pool
        if(wethEstimate > 0){
            ILooksRareFee(LooksRareStaking).harvest();

            //Swap any weth into Looks via Univ2 router
            address[] memory path = new address[](2);
            path[0] = address(WETH);
            path[1] = address(LOOKSToken);
            uint256 expTime = block.timestamp + 3600;
            uint256[] memory returnedAmounts = IUniswapV2Router02(univ2Router).swapExactTokensForTokens(IERC20(WETH).balanceOf(address(this)),0,path,address(this),expTime);
            swapAmount = returnedAmounts[1];
            emit swapAmountEvent(swapAmount);
        }

        //Get current share value in LOOKS
        uint256 currentShareValue = ILooksRareFee(LooksRareStaking).calculateSharesValueInLOOKS(address(this));
        emit prepareReturnSharesValueEvent(currentShareValue);

        //calculate the rough profit to so we can withdraw it and pass the vault.report balance check.
        LOOKSprofit = currentShareValue.add(IERC20(LOOKSToken).balanceOf(address(this)));
        
        uint256 estFinalProfit = LOOKSprofit.sub(vaultDebt);

        uint256 sharePrice = ILooksRareFee(LooksRareStaking).calculateSharePriceInLOOKS();
        uint256 withdrawPreReport = estFinalProfit.mul(1e18).div(sharePrice);
        emit withdrawPreReportEvent(withdrawPreReport);

        if(withdrawPreReport > 1){
            //withdraw the profit amount and add in the claim
            ILooksRareFee(LooksRareStaking).withdraw(withdrawPreReport,false);
        }
        //readjust final profit report in case of changes in balances.
        currentShareValue = ILooksRareFee(LooksRareStaking).calculateSharesValueInLOOKS(address(this));
        LOOKSprofit = currentShareValue.add(IERC20(LOOKSToken).balanceOf(address(this)));
        emit LOOKSProfitEvent(LOOKSprofit);
        uint256 finalProfit = LOOKSprofit.sub(vaultDebt);


        emit finalProfitEvent(finalProfit);
        uint256 balanceCheck = want.balanceOf(address(this));
        emit balanceCheckEvent(balanceCheck);
        //If there is no debt outstanding, deposit all looks back into contract and report back profit
        emit debtOutstandingEvent(_debtOutstanding);
        if(_debtOutstanding == 0){
            return(finalProfit,0,0);
        } else {
            //If there is debt but our balance exceeds the debt, then we can deposit the extra looks back into staking
            if(want.balanceOf(address(this)) > _debtOutstanding){
                return(finalProfit,0,_debtOutstanding);
            } else {
                //Otherwise report back the balance all as debt payment
                return(finalProfit,0,want.balanceOf(address(this))); 
            }
        }
    }
    
event toDepositEvent(uint256 _amount);
event toDepositFloorEvent(uint256 _amount);
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        //no need for us to use debt as we can always pull it out.
        uint256 debt = _debtOutstanding;

        //Figure out how much can be deposited
        uint256 toDeposit = want.balanceOf(address(this));
        emit toDepositEvent(toDeposit);

        //set deposit floor as the looks contract doesn't allow staking below 1 LOOKS
        uint256 depositFloor = 1 * 10 ** 18;
        emit toDepositFloorEvent(depositFloor);

        //Deposit without claim as we'll claim rewards only on a prepare to better track.
        if(toDeposit > depositFloor){
            ILooksRareFee(LooksRareStaking).deposit(toDeposit,false);
        }
    }

    function firstTimeApprovals() public {
        //check if tokens are approved as needed.
        if(IERC20(LOOKSToken).allowance(address(this),LooksRareStaking) == 0){
            IERC20(LOOKSToken).approve(LooksRareStaking, hash);
        }
        if(IERC20(LOOKSToken).allowance(address(this),univ2Router) == 0){
            IERC20(LOOKSToken).approve(univ2Router, hash);
        }
        if(IERC20(WETH).allowance(address(this),univ2Router) == 0){
            IERC20(WETH).approve(univ2Router, hash);
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
        uint256 liveShareValue = ILooksRareFee(LooksRareStaking).calculateSharesValueInLOOKS(address(this));
        uint256 generalSharePrice = ILooksRareFee(LooksRareStaking).calculateSharePriceInLOOKS();
        emit sharePriceCompareEvent(generalSharePrice);
        emit liveShareValueEvent(liveShareValue);
        (uint256 shares, , ) = ILooksRareFee(LooksRareStaking).userInfo(address(this));
        emit sharesOwnedEvent(shares);
        uint256 sharesNeeded = _amountNeeded.mul(1e18).div(generalSharePrice);
        emit sharedNeededEvent(sharesNeeded);
        if(_amountNeeded != 0){
            if(sharesNeeded < shares){
                ILooksRareFee(LooksRareStaking).withdraw(sharesNeeded,false);

            } else {
                ILooksRareFee(LooksRareStaking).withdrawAll(true);
            }
        }

        uint256 totalAssets = want.balanceOf(address(this));
        emit postWithdrawBalanceEvent(totalAssets);

        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
            return(_liquidatedAmount, _loss);
        } else {
            _liquidatedAmount = _amountNeeded;
            return(_liquidatedAmount,0);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        adjustPosition(0);
        ILooksRareFee(LooksRareStaking).withdrawAll(true);
        return want.balanceOf(address(this));
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