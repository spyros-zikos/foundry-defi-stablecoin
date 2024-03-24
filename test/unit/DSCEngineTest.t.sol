// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // worth $2000 dollars each (for weth)
    uint256 public constant AMOUNT_MINT = 5 ether; // worth $1 each
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    ///////////////////
    // Events    //////
    ///////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    ///////////////////
    // Modifiers     //
    ///////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier mintDsc() {
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT_MINT);
        vm.stopPrank();
        _;
    }

    ///////////////////
    // Functions     //
    ///////////////////

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////////
    // Constructor Tests      //
    ////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////
    // Price Tests      //
    //////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; // 15e18(ETH) * 2000($/ETH) = $30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////////
    // depositCollateral Tests      //
    //////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.deal(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testEmitEventAfterDeposit() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce)); // 3 topics, 1 data, 1 emiter address
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////////////
    // _healthFactor()      //
    //////////////////////////

    function testHealthFactorWorks() public depositedCollateral {
        uint256 MINT_AMOUNT = 2 ether;
        uint256 expectedHealthFactor = ((10 * 2000e18 * 1e18) / 2) / MINT_AMOUNT; // 10 eth deposited, 2000e18 is the $price of 1 eth, /2 for 200% overcollateralization

        uint256 actualHealthFactor = dsce.getHealthFactor(USER);
        assert(actualHealthFactor > 1);

        vm.startPrank(USER);
        dsce.mintDsc(MINT_AMOUNT);
        vm.stopPrank();

        actualHealthFactor = dsce.getHealthFactor(USER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    ///////////////////
    // burnDsc()     //
    ///////////////////

    function testBurnDscWithoutCollateral() public {
        vm.expectRevert();
        vm.startPrank(USER);
        dsce.burnDsc(1 ether);
        vm.stopPrank();
    }

    function testBurnDscWorks() public depositedCollateral mintDsc {
        uint256 burnAmount = 1 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), burnAmount);
        dsce.burnDsc(burnAmount);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, AMOUNT_MINT - burnAmount);
    }

    ////////////////////////////////////
    // depositCollateralAndMintDsc()  //
    ////////////////////////////////////

    function testDepositCollateralAndMintDscWorks() public {
        uint256 AMOUNT_COLLATERAL_IN_USD = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT * 2000);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, AMOUNT_MINT * 2000);
        assertEq(collateralValueInUsd, AMOUNT_COLLATERAL_IN_USD);
    }

    function testDepositCollateralAndMintDscDoesntBreakHealthFactor() public {
        uint256 dscMint = AMOUNT_MINT * 2000 + 1;
        uint256 AMOUNT_COLLATERAL_IN_USD = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor =
            (((AMOUNT_COLLATERAL_IN_USD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION) * PRECISION) / dscMint;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, dscMint);
        vm.stopPrank();
    }

    ///////////////////////////
    // redeemCollateral()    //
    ///////////////////////////

    function testRedeemCollateralWorks() public depositedCollateral {
        uint256 collateralToGet = AMOUNT_COLLATERAL / 2;

        vm.startPrank(USER);
        dsce.redeemCollateral(weth, collateralToGet);
        vm.stopPrank();
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        assert(dsce.getHealthFactor(USER) >= MIN_HEALTH_FACTOR);
        assertEq(collateralValueInUsd, (AMOUNT_COLLATERAL - collateralToGet) * 2000);
    }

    /////////////////////////////////
    // redeemCollateralForDsc()    //
    /////////////////////////////////

    function testRedeemCollateralForDscWorks() public depositedCollateral mintDsc {
        uint256 collateralToGet = AMOUNT_COLLATERAL / 2;
        uint256 dscToGive = AMOUNT_MINT / 2;

        vm.startPrank(USER);
        dsc.approve(address(dsce), dscToGive);
        dsce.redeemCollateralForDsc(weth, collateralToGet, dscToGive);
        vm.stopPrank();

        assert(dsce.getHealthFactor(USER) >= MIN_HEALTH_FACTOR);
    }

    ////////////////////
    // liquidate()    //
    ////////////////////

    function testLiquidateUserFully() public depositedCollateral mintDsc {
        uint256 startingHealthFactor = dsce.getHealthFactor(USER);

        vm.startBroadcast();
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(9e7); // previous 2000e8
        vm.stopBroadcast();
        uint256 badHealthFactor = dsce.getHealthFactor(USER);

        // liquidator mint weth
        uint256 liquidatorEthBalance = STARTING_ERC20_BALANCE * 1000000;
        ERC20Mock(weth).mint(LIQUIDATOR, liquidatorEthBalance);
        // liquidator mint dsc for weth
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), liquidatorEthBalance);
        dsce.depositCollateralAndMintDsc(weth, liquidatorEthBalance, AMOUNT_MINT);
        // fully liquidate user
        dsc.approve(address(dsce), AMOUNT_MINT);
        dsce.liquidate(weth, USER, AMOUNT_MINT);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);

        assert(startingHealthFactor >= MIN_HEALTH_FACTOR);
        assert(badHealthFactor < MIN_HEALTH_FACTOR);
        assertEq(totalDscMinted, 0);
    }

    function testLiquidateUserPartially() public depositedCollateral mintDsc {
        uint256 startingHealthFactor = dsce.getHealthFactor(USER);

        // price of eth drops -> user is not 200% or more overcollateralized
        vm.startBroadcast();
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(9e7); // previous 2000e8
        vm.stopBroadcast();
        uint256 badHealthFactor = dsce.getHealthFactor(USER);

        // liquidator mint weth
        uint256 liquidatorEthBalance = STARTING_ERC20_BALANCE * 1000000;
        ERC20Mock(weth).mint(LIQUIDATOR, liquidatorEthBalance);
        // liquidator mint dsc for weth
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), liquidatorEthBalance);
        dsce.depositCollateralAndMintDsc(weth, liquidatorEthBalance, AMOUNT_MINT / 2);
        // partially liquidate user
        dsc.approve(address(dsce), AMOUNT_MINT / 2);
        dsce.liquidate(weth, USER, AMOUNT_MINT / 2);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);

        assert(startingHealthFactor >= MIN_HEALTH_FACTOR);
        assert(badHealthFactor < MIN_HEALTH_FACTOR);
        assertEq(totalDscMinted, AMOUNT_MINT / 2);
    }

    function testLiquidateHealthyUser() public depositedCollateral mintDsc {
        // liquidator mint weth
        uint256 liquidatorEthBalance = STARTING_ERC20_BALANCE * 1000000;
        ERC20Mock(weth).mint(LIQUIDATOR, liquidatorEthBalance);
        // liquidator mint dsc for weth
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), liquidatorEthBalance);
        dsce.depositCollateralAndMintDsc(weth, liquidatorEthBalance, AMOUNT_MINT);
        // try to fully liquidate user
        dsc.approve(address(dsce), AMOUNT_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_MINT);
        vm.stopPrank();
    }

    /////////////////////////////////
    // getAccountCollateralValue   //
    /////////////////////////////////

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 expectedUserCollateralValue = AMOUNT_COLLATERAL * 2000;
        uint256 actualUserCollateralValue = dsce.getAccountCollateralValue(USER);
        assertEq(expectedUserCollateralValue, actualUserCollateralValue);
    }
}
