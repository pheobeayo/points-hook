// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG |
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        deployCodeTo("PointsHook.sol", abi.encode(manager), address(flags));

        // Deploy our hook
        hook = PointsHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.1 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );
        uint256 tokenToAdd = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            liquidityDelta
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(
            address(this),
            poolIdUint
        );

        // Set user address in hook data
        bytes memory hookData = abi.encode(address(this));

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(
            address(this),
            poolIdUint
        );
        assertEq(pointsBalanceAfterSwap - pointsBalanceOriginal, 2 * 10 ** 14);
    }

    function _addLiquidity(bytes memory hookData) internal returns (uint256 ethSpent) {
        uint256 ethBefore = address(this).balance;
        modifyLiquidityRouter.modifyLiquidity{value: 0.1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(0)
            }),
            hookData
        );
        ethSpent = ethBefore - address(this).balance;
    }

    function test_addLiquidity_mintsPoints() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        uint256 ethSpent = _addLiquidity(abi.encode(address(this)));

        assertGt(ethSpent, 0);
        assertEq(
            hook.balanceOf(address(this), poolIdUint) - pointsBefore,
            ethSpent / 10
        );
    }

    function test_addLiquidity_noHookData_noPoints() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        uint256 ethSpent = _addLiquidity(ZERO_BYTES);

        assertGt(ethSpent, 0);
        assertEq(hook.balanceOf(address(this), poolIdUint), pointsBefore);
    }

    // ---------------------------------------------------------------
    // Remove-liquidity burn
    // ---------------------------------------------------------------

    // A fresh salt keeps these positions separate from the setUp liquidity
    bytes32 constant SALT = bytes32(uint256(1));
    address constant ALICE = address(0xA11CE);

    function _poolIdUint() internal view returns (uint256) {
        return uint256(PoolId.unwrap(key.toId()));
    }

    function _modify(int256 liquidityDelta, bytes memory hookData) internal {
        modifyLiquidityRouter.modifyLiquidity{
            value: liquidityDelta > 0 ? 0.1 ether : 0
        }(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: liquidityDelta,
                salt: SALT
            }),
            hookData
        );
    }

    function test_removeLiquidity_full_burnsAllLpPoints() public {
        _modify(1 ether, abi.encode(address(this)));
        assertGt(hook.balanceOf(address(this), _poolIdUint()), 0);

        // No hookData on removal: the LP can't dodge the burn by omitting it
        _modify(-1 ether, ZERO_BYTES);

        assertEq(hook.balanceOf(address(this), _poolIdUint()), 0);
        (address owner, uint128 liq, uint256 pts) = hook.lpRecords(key.toId(), _posKey());
        assertEq(owner, address(0));
        assertEq(liq, 0);
        assertEq(pts, 0);
    }

    function test_removeLiquidity_partial_burnsProportionally() public {
        _modify(1 ether, abi.encode(address(this)));
        uint256 earned = hook.balanceOf(address(this), _poolIdUint());

        _modify(-0.25 ether, ZERO_BYTES);

        uint256 expectedBurn = earned / 4;
        assertEq(hook.balanceOf(address(this), _poolIdUint()), earned - expectedBurn);
        (, uint128 liq, uint256 pts) = hook.lpRecords(key.toId(), _posKey());
        assertEq(liq, 0.75 ether);
        assertEq(pts, earned - expectedBurn);
    }

    function test_removeLiquidity_keepsSwapPoints() public {
        // Earn swap points and LP points, then exit the LP position
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this))
        );
        uint256 swapPoints = hook.balanceOf(address(this), _poolIdUint());

        _modify(1 ether, abi.encode(address(this)));
        _modify(-1 ether, ZERO_BYTES);

        assertEq(hook.balanceOf(address(this), _poolIdUint()), swapPoints);
    }

    function test_removeLiquidity_cannotBurnSomeoneElsesPoints() public {
        // Alice earns swap points
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(ALICE)
        );
        uint256 alicePoints = hook.balanceOf(ALICE, _poolIdUint());
        assertGt(alicePoints, 0);

        // We add and remove our own liquidity, naming Alice on removal
        _modify(1 ether, abi.encode(address(this)));
        _modify(-1 ether, abi.encode(ALICE));

        assertEq(hook.balanceOf(ALICE, _poolIdUint()), alicePoints);
        assertEq(hook.balanceOf(address(this), _poolIdUint()), 0);
    }

    function test_addLiquidity_secondRecipientOnSamePosition_noPoints() public {
        _modify(1 ether, abi.encode(address(this)));
        _modify(1 ether, abi.encode(ALICE));

        assertEq(hook.balanceOf(ALICE, _poolIdUint()), 0);
    }

    function test_removeLiquidity_afterTransferringPoints_doesNotRevert() public {
        _modify(1 ether, abi.encode(address(this)));
        uint256 earned = hook.balanceOf(address(this), _poolIdUint());

        // Move most points away before withdrawing
        hook.safeTransferFrom(address(this), ALICE, _poolIdUint(), earned - 1, "");

        _modify(-1 ether, ZERO_BYTES);

        // Burn is capped at what's left; withdrawal still succeeds
        assertEq(hook.balanceOf(address(this), _poolIdUint()), 0);
        assertEq(hook.balanceOf(ALICE, _poolIdUint()), earned - 1);
    }

    function test_removeLiquidity_untrackedPosition_noBurn() public {
        // Liquidity added with no recipient never earned points, so removal burns nothing
        _modify(1 ether, abi.encode(address(this)));
        uint256 earned = hook.balanceOf(address(this), _poolIdUint());

        // Remove from the setUp position (salt 0), which never earned points
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -0.5 ether,
                salt: bytes32(0)
            }),
            abi.encode(address(this))
        );

        assertEq(hook.balanceOf(address(this), _poolIdUint()), earned);
    }

    function _posKey() internal view returns (bytes32) {
        return Position.calculatePositionKey(address(modifyLiquidityRouter), -60, 60, SALT);
    }
}
