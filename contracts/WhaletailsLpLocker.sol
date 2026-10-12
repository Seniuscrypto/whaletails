// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPositionManager {
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,
        uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1);
}

/// @title Whaletails LP locker (Robinhood Chain)
/// @notice Holds Uniswap v3 launch positions FOREVER. There is no function that
///         removes liquidity or moves a position out: once a position is sent
///         here, its liquidity is locked for good. Trading fees can be collected
///         by anyone at any time and are split 50/50 between the coin's creator
///         and the platform, the same split as the Solana side.
contract WhaletailsLpLocker {
    using SafeERC20 for IERC20;

    IPositionManager public immutable positionManager;
    address public platform;
    mapping(uint256 => address) public creatorOf;

    event Locked(uint256 indexed tokenId, address indexed creator);
    event FeesCollected(uint256 indexed tokenId, address token0, uint256 creator0, uint256 platform0, address token1, uint256 creator1, uint256 platform1);
    event CreatorChanged(uint256 indexed tokenId, address creator);
    event PlatformChanged(address platform);

    constructor(address _positionManager, address _platform) {
        require(_positionManager != address(0) && _platform != address(0), "zero address");
        positionManager = IPositionManager(_positionManager);
        platform = _platform;
    }

    /// @dev Positions arrive by safeTransferFrom(owner, locker, tokenId, abi.encode(creator)).
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        require(msg.sender == address(positionManager), "only Uniswap positions");
        address creator = data.length == 32 ? abi.decode(data, (address)) : address(0);
        require(creator != address(0), "creator required");
        creatorOf[tokenId] = creator;
        emit Locked(tokenId, creator);
        return this.onERC721Received.selector;
    }

    /// @notice Anyone may call: collects the position's fees and pays both halves.
    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        address creator = creatorOf[tokenId];
        require(creator != address(0), "not locked here");
        (amount0, amount1) = positionManager.collect(IPositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
        (, , address token0, address token1, , , , , , , , ) = positionManager.positions(tokenId);
        uint256 c0 = amount0 / 2;
        uint256 c1 = amount1 / 2;
        _pay(token0, creator, c0); _pay(token0, platform, amount0 - c0);
        _pay(token1, creator, c1); _pay(token1, platform, amount1 - c1);
        emit FeesCollected(tokenId, token0, c0, amount0 - c0, token1, c1, amount1 - c1);
    }

    /// @notice The creator can hand their fee share to another wallet.
    function setCreator(uint256 tokenId, address creator) external {
        require(msg.sender == creatorOf[tokenId], "only creator");
        require(creator != address(0), "zero address");
        creatorOf[tokenId] = creator;
        emit CreatorChanged(tokenId, creator);
    }

    function setPlatform(address _platform) external {
        require(msg.sender == platform, "only platform");
        require(_platform != address(0), "zero address");
        platform = _platform;
        emit PlatformChanged(_platform);
    }

    function _pay(address token, address to, uint256 amount) private {
        if (amount > 0) IERC20(token).safeTransfer(to, amount);
    }
}
