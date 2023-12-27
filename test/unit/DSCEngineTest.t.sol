// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {console} from "forge-std/console.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 public deployerKey;

    uint256 public amountToMint = 100 ether;
    address public user = makeAddr("user");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run(); // the owner of dsc is dscEngine now
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    /////////////////////////
    // Constructor Tests   //
    /////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeEqualLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////
    // Price Tests   //
    ///////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; //  15 ETH
        // 15e18 * 1000/ETH  = 15,000e18
        uint256 expectedUsdValue = 15e18 * 1000;
        uint256 actualUsdValue = dscEngine.getUSDValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 udsAmount = 100 ether;
        // $ 1000 / ETH, $100 USD = 100/1000 ETH = 0.1 ETH
        uint256 expectedWeth = 0.1 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, udsAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    // depositCollateral Tests   //
    ///////////////////////////////

    // This test has it's own setup
    function testRevertIfTransferFromFails() public {
        console.log("msg.sender");
        console.logAddress(msg.sender);
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine innerDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        mockDsc.mint(user, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(innerDscEngine));

        // Arragne - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(innerDscEngine), AMOUNT_COLLATERAL);
        //Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        innerDscEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("Random", "RND", user, 1000);
        vm.startPrank(user);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowToken.selector);
        dscEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralDeposited = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralDeposited);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////
    function testRevertsIfMintedDscBreaksHealthFactor() public {
        // Arrange - Setup (get the price and mint the collateral)
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // This value is in USD, since 1 DSC = 1 USD. 10 * $1000 = $10,000
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalPriceFeedPrecision()))
            / dscEngine.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUSDValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testMaxDSCMintWithoutBreakingHealthFactor() public {
        // Arrange - Setup (get the price and mint the collateral)
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // This value is in USD, since 1 DSC = 1 USD. 10 * $1000 = $10,000

        uint256 usdValue = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalPriceFeedPrecision()))
            / dscEngine.getPrecision();
        amountToMint = usdValue * dscEngine.getLiquidationThreshold() / dscEngine.getLiquidationPrecision();

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testMaxDSCMintPlus1BreaksHealthFactor() public {
        // Arrange - Setup (get the price and mint the collateral)
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // This value is in USD, since 1 DSC = 1 USD. 10 * $1000 = $10,000

        uint256 usdValue = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalPriceFeedPrecision()))
            / dscEngine.getPrecision();
        amountToMint = (usdValue * dscEngine.getLiquidationThreshold()) / dscEngine.getLiquidationPrecision();
        amountToMint += 1;

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUSDValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ////////////////////
    // mintDsc Tests //
    //////////////////

    // This test has it's own setup
    function testRevertIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;

        vm.prank(owner);
        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));

        // Arragne - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dscEngine.mintDSC(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // We are minting the same amount of DSC as the collateral, this will break the health factor since it should be 200% overcollateralized
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalPriceFeedPrecision()))
            / dscEngine.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUSDValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    ////////////////////
    // burnDSC Tests //
    //////////////////

    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint); // approve the dscEngine to use 10 DSC from user
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public depositedCollateralAndMintedDsc {
        // user has no DSC
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert();
        dscEngine.burnDSC(amountToMint + 1);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDSC(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)]; // we are using a mock ERC20 that will fail on transfer as possible collateral
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine innerDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(user, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(innerDscEngine));

        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(innerDscEngine), AMOUNT_COLLATERAL);
        // Act
        innerDscEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        innerDscEngine.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, STARTING_USER_BALANCE);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemWithCorrectArgs() public depositedCollateral {
        // event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);
        //  3 indexed and the data
        // We need to create the event in the test, because it can't be emmitted from other contracts
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL);
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDSC(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        // burns amountToMint DSC and redeems AMOUNT_COLLATERAL
        dscEngine.redeemCollateralForDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBlance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBlance, STARTING_USER_BALANCE);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        // deposit 10 ETH, mint 100 DSC
        // Each ETH is worth $1000, so 10 ETH = $10,000
        // 100 DSC = $100
        // With a liquidation threshold of 50%, means that we should have $200 collateral at all times
        // $10,000 * 0.5 = $5,000
        // $5,000 / $100 = 50
        uint256 expectedHealthFactor = 50 ether;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(user);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUpdatedPrice); // This will update the price of ETH to $18

        // deposit 10 ETH, mint 100 DSC
        // Each ETH is worth $18, so 10 ETH = $180
        // 100 DSC = $100
        // With a liquidation threshold of 50%, means that we should have $200 collateral at all times
        // $180 * 0.5 = $90
        // $90 / $100 = 0.9

        uint256 expectedHealthFactor = 0.9 ether;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(user);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test has it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine innerDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(innerDscEngine));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(innerDscEngine), AMOUNT_COLLATERAL);
        // User deposits 10 ETH = $10,000, mints 100 DSC = $100 => Health Factor = 50
        innerDscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(innerDscEngine), collateralToCover);
        uint256 debtToCover = 10 ether; // 10 DSC
        // Deposit 1 ETH = $1000, mint $100 DSC = 100 DSC
        innerDscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(innerDscEngine), debtToCover);

        // Act
        int256 ethUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUpdatedPrice); // This will update the price of ETH to $18
        // User has 100 DSC = $100, 10 ETH = $180
        // Liquidator has 100 DSC = $100, 1 ETH = $18
        // It will try to liquidate 10 DSC from the user, which is not enough to cover the debt, so it will revert
        // We need at least $20 to cover the debt,

        uint256 userHearthFactor = innerDscEngine.getHealthFactor(user);
        console.log("userHearthFactor");
        console.logUint(userHearthFactor);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        innerDscEngine.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        // Arrange - Liquidator
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        // deposit 20 ETH = $20,000, mint 100 DSC = $100
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    function testMinimunDebtToCover() public depositedCollateralAndMintedDsc {
        // Arrange - Liquidator
        // Liquidator has 20 ETH = $20,000, 100 DSC = $100
        ERC20Mock(weth).mint(liquidator, collateralToCover);
        vm.startPrank(liquidator);
        // Arrange - Liquidator
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        // deposit 20 ETH = $20,000, mint 100 DSC = $100
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        int256 ethUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUpdatedPrice); // This will update the price of ETH to $18
        // User has 100 DSC = $100, 10 ETH = $180 => Health Factor = 0.9 ($180/2 = $90 / $100 = 0.9)
        // Liquidator has 100 DSC = $100, 20 ETH = $360 => Health Factor = 1.8
        // In order to make the system healthy, the liquidator needs to cover at least $x of debt
        // bebause ($180 - 1,1x) / 2 = ($90 - 0.55x) / ($100 - x) = 1 => x = $22,2222222222

        uint256 userHearthFactor = dscEngine.getHealthFactor(user);
        console.log("userHearthFactor");
        console.logUint(userHearthFactor);

        uint256 minimunDebtToCover = 22222222222222222222; // 22.222222222222222222 DSC
        dscEngine.liquidate(weth, user, minimunDebtToCover);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        console.log("totalDscMinted");
        console.logUint(totalDscMinted);
        console.log("collateralValueInUsd");
        console.logUint(collateralValueInUsd);
        uint256 userHearthFactorAfterLiquidation = dscEngine.getHealthFactor(user);
        console.log("userHearthFactorAfterLiquidation");
        console.logUint(userHearthFactorAfterLiquidation);

        // If now we try to liquidate the user, it will fail because the health factor is good
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dscEngine.liquidate(weth, user, 0.01 ether);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint); // We are covering their whole debt (amountToMint) 100 DSC
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);

        uint256 expectedLiquidatorWethBalance = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus());

        assertEq(liquidatorWethBalance, expectedLiquidatorWethBalance);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // calculate how much ETH the user should have after liquidation
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus());
        uint256 usdAmountLiquidated = dscEngine.getUSDValue(weth, amountLiquidated);
        uint256 expectedUserCollateralInUSD = dscEngine.getUSDValue(weth, AMOUNT_COLLATERAL) - usdAmountLiquidated;

        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        assertEq(collateralValueInUsd, expectedUserCollateralInUSD);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        // The liquidator still has a debt of 100 DSC, but not the user
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }
}
