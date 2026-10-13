// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IUniswapV3PoolMin {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

/// @title Whaletails price setter
/// @notice Moves an EMPTY Uniswap v3 pool to a target price before launch liquidity goes in, so a
///         pool someone created early at a wrong price cannot be used to buy a launch for nothing.
///         With no liquidity in the way the swap moves only the price and costs nothing; the
///         callback refuses to pay anything, so on a pool that holds liquidity it simply reverts.
///         (Uniswap's routers refuse swaps through empty ranges, hence this contract.)
contract WhaletailsPriceSetter {
    function setPrice(address pool, uint160 sqrtPriceX96Target) external {
        (uint160 current,,,,,,) = IUniswapV3PoolMin(pool).slot0();
        if (current == sqrtPriceX96Target) return;
        IUniswapV3PoolMin(pool).swap(address(this), current > sqrtPriceX96Target, 1, sqrtPriceX96Target, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external pure {
        require(amount0Delta <= 0 && amount1Delta <= 0, "pool is not empty");
    }
}
