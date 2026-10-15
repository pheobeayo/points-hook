// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Position} from "v4-core/libraries/Position.sol";

contract PointsHook is BaseHook, ERC1155 {
    /// @notice Points earned by providing liquidity to one position, and who earned them.
    /// @dev `liquidity` is the portion of the position's liquidity that earned points.
    ///      Liquidity added without a recipient is untracked and never earns or burns points.
    struct LpRecord {
        address owner;
        uint128 liquidity;
        uint256 points;
    }

    /// @notice poolId => PoolManager position key => LP points record
    mapping(PoolId => mapping(bytes32 => LpRecord)) public lpRecords;

    event LpPointsBurned(address indexed owner, PoolId indexed poolId, uint256 points);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function uri(uint256) public view virtual override returns (string memory) {
        return "https://api.example.com/token/{id}";
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since its a zeroForOne swap:
        // if amountSpecified < 0:
        //      this is an "exact input for output" swap
        //      amount of ETH they spent is equal to |amountSpecified|
        // if amountSpecified > 0:
        //      this is an "exact output for input" swap
        //      amount of ETH they spent is equal to BalanceDelta.amount0()

        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        // Mint the points
        _assignPoints(key.toId(), hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    /// @notice Reward liquidity providers with points worth 10% of the ETH they deposit.
    /// @dev `delta` is the caller's delta, which includes any fees collected from an
    ///      existing position. Subtracting `feesAccrued` leaves only the principal,
    ///      so topping up a position can't farm points from collected fees.
    ///      The first address to earn points on a position becomes its owner; other
    ///      addresses can't earn points on it, so a burn always has one clear target.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Only ETH-TOKEN pools earn points
        if (!key.currency0.isAddressZero()) {
            return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        address user = _decodeUser(hookData);
        if (user == address(0)) {
            return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        // Adding liquidity makes amount0 negative (ETH flows into the pool)
        int128 principal0 = (delta - feesAccrued).amount0();
        if (principal0 >= 0) {
            return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        PoolId poolId = key.toId();
        LpRecord storage record = lpRecords[poolId][_positionKey(sender, params)];
        if (record.owner == address(0)) {
            record.owner = user;
        } else if (record.owner != user) {
            // Position's points already belong to someone else
            return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        uint256 points = uint256(int256(-principal0)) / 10;
        record.liquidity += uint128(uint256(params.liquidityDelta));
        record.points += points;
        _mint(user, uint256(PoolId.unwrap(poolId)), points, "");

        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Burn LP points in proportion to the point-earning liquidity removed.
    /// @dev Ignores hookData on purpose: the burn target comes from the position's
    ///      record, so an LP can't dodge the burn by omitting hookData and nobody can
    ///      burn someone else's points by naming them. Point-earning liquidity is
    ///      treated as removed first. The burn is capped at the owner's balance so a
    ///      withdrawal never reverts if they've transferred points away.
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = _positionKey(sender, params);
        LpRecord storage record = lpRecords[poolId][positionKey];

        uint128 removed = uint128(uint256(-params.liquidityDelta));
        if (record.liquidity == 0 || removed == 0) {
            return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
        }

        uint128 removedTracked = removed < record.liquidity ? removed : record.liquidity;
        uint256 toBurn = (record.points * removedTracked) / record.liquidity;

        address owner = record.owner;
        if (removedTracked == record.liquidity) {
            // All point-earning liquidity is gone; free the position for a new owner
            toBurn = record.points;
            delete lpRecords[poolId][positionKey];
        } else {
            record.liquidity -= removedTracked;
            record.points -= toBurn;
        }

        uint256 id = uint256(PoolId.unwrap(poolId));
        uint256 balance = balanceOf[owner][id];
        if (toBurn > balance) toBurn = balance;
        if (toBurn > 0) {
            _burn(owner, id, toBurn);
            emit LpPointsBurned(owner, poolId, toBurn);
        }

        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _positionKey(
        address sender,
        ModifyLiquidityParams calldata params
    ) internal pure returns (bytes32) {
        return Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
    }

    function _decodeUser(bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 0) return address(0);
        return abi.decode(hookData, (address));
    }

    function _assignPoints(
        PoolId poolId,
        bytes calldata hookData,
        uint256 points
    ) internal {
        // If no hookData is passed in, no points will be assigned to anyone
        if (hookData.length == 0) return;

        // Extract user address from hookData
        address user = abi.decode(hookData, (address));

        // If there is hookData but not in the format we're expecting and user address is zero
        // nobody gets any points
        if (user == address(0)) return;

        // Mint points to the user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        _mint(user, poolIdUint, points, "");
    }
}
