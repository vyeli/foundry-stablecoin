// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public user = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
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
}
