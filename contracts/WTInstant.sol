// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/* Whale Tail INSTANT launch for any EVM chain (2026-10-18): the coin opens straight
   into a locked PancakeSwap v3 / Uniswap v3 pool, so it trades and shows on DEX screeners and terminals (Axiom, GMGN,
   DexScreener) from its first trade. One transaction from the creator's wallet:
   - a fixed 1,000,000,000 supply coin, no owner, no mint, no blocklist;
   - its pool created in the SAME transaction (nobody can create it first at another price), 1% fee tier;
   - the whole supply placed as ONE-SIDED liquidity starting exactly at the opening price and running to the top of
     the range: buyers bring the native coin, the price rises from there, and nobody needs to seed native liquidity;
   - the position locked forever in the Whale Tail locker (pool fees split 50/50 creator / platform by the locker);
   - the creator's opening buy is the pool's first trade (it makes the coin show up and gives the creator the first coins).
   The opening tick and its sqrt prices are computed off chain once and fixed in the factory (no tick math on chain). */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IWETH9i { function deposit() external payable; function transfer(address, uint256) external returns (bool); function approve(address, uint256) external returns (bool); }
interface IV3PoolI { function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256, int256); }
interface INPMi {
  struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired;
    uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }
  function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96) external payable returns (address);
  function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
  function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

contract WTInstantToken is ERC20 {
  constructor(string memory name_, string memory symbol_, address to) ERC20(name_, symbol_) { _mint(to, 1_000_000_000 ether); }
}

contract WTInstantFactory is ReentrancyGuard {
  uint256 public constant SUPPLY = 1_000_000_000 ether;
  uint24 public constant FEE = 10000;                     // the 1% tier (tick spacing 200 on Uniswap and PancakeSwap)
  int24 public constant MAX_TICK = 887200;                // the top usable tick at spacing 200
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
  address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

  address public owner;
  address public platform;
  uint256 public launchFee;
  address public immutable weth;
  address public immutable npm;
  address public immutable locker;
  int24 public immutable startTick;                       // when the coin is token0: price (native per coin) = 1.0001^startTick
  uint160 public immutable sqrtAtStart;                   // sqrtPriceX96 at startTick
  uint160 public immutable sqrtAtNegStart;                // sqrtPriceX96 at -startTick (the coin is token1)
  address[] public allTokens;
  mapping(address => address) public poolOf;
  address private swapPool;

  event Launched(address indexed token, address indexed pool, address indexed creator, string name, string symbol, uint256 buyEth, uint256 tokensOut, uint256 positionId);
  event ParamsSet(uint256 launchFee, address platform);

  constructor(address weth_, address npm_, address locker_, address platform_, uint256 launchFee_, int24 startTick_, uint160 sqrtAtStart_, uint160 sqrtAtNegStart_) {
    require(weth_ != address(0) && npm_ != address(0) && locker_ != address(0) && platform_ != address(0), "bad config");
    require(startTick_ % 200 == 0 && startTick_ > -MAX_TICK && startTick_ < MAX_TICK, "bad start tick");
    owner = msg.sender; weth = weth_; npm = npm_; locker = locker_; platform = platform_; launchFee = launchFee_;
    startTick = startTick_; sqrtAtStart = sqrtAtStart_; sqrtAtNegStart = sqrtAtNegStart_;
  }
  modifier onlyOwner() { require(msg.sender == owner, "only the owner"); _; }
  function setParams(uint256 launchFee_, address platform_) external onlyOwner { require(platform_ != address(0), "bad platform"); launchFee = launchFee_; platform = platform_; emit ParamsSet(launchFee_, platform_); }
  function setOwner(address o) external onlyOwner { require(o != address(0), "bad owner"); owner = o; }
  function launchCount() external view returns (uint256) { return allTokens.length; }

  function launch(string calldata name_, string calldata symbol_, uint256 minTokensOut) external payable nonReentrant returns (address token, address pool, uint256 positionId) {
    require(bytes(name_).length > 0 && bytes(name_).length <= 32 && bytes(symbol_).length > 0 && bytes(symbol_).length <= 10, "bad name or ticker");
    require(msg.value >= launchFee, "the launch fee is missing");
    token = address(new WTInstantToken(name_, symbol_, address(this)));
    bool coinIs0 = token < weth;
    (address t0, address t1) = coinIs0 ? (token, weth) : (weth, token);
    pool = INPMi(npm).createAndInitializePoolIfNecessary(t0, t1, FEE, coinIs0 ? sqrtAtStart : sqrtAtNegStart);
    require(IERC20(token).approve(npm, SUPPLY), "approve failed");
    /* one-sided: the coin only, from the opening price to the top (coin = token0), or from the bottom to it (token1) */
    (uint256 id, , uint256 used0, uint256 used1) = INPMi(npm).mint(INPMi.MintParams({ token0: t0, token1: t1, fee: FEE,
      tickLower: coinIs0 ? startTick : -MAX_TICK, tickUpper: coinIs0 ? MAX_TICK : -startTick,
      amount0Desired: coinIs0 ? SUPPLY : 0, amount1Desired: coinIs0 ? 0 : SUPPLY, amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp }));
    require((coinIs0 ? used1 : used0) == 0, "the position would need native liquidity");
    positionId = id;
    INPMi(npm).safeTransferFrom(address(this), locker, id, abi.encode(msg.sender));
    uint256 dust = IERC20(token).balanceOf(address(this));       // rounding: what the position could not take is burned
    if (dust > 0) require(IERC20(token).transfer(DEAD, dust), "burn failed");
    poolOf[token] = pool;
    allTokens.push(token);
    if (launchFee > 0) { (bool ok, ) = platform.call{value: launchFee}(""); require(ok, "fee transfer failed"); }
    uint256 buyEth = msg.value - launchFee;
    uint256 out = 0;
    if (buyEth > 0) {
      /* the opening buy: the pool's first trade, the coins straight to the creator */
      IWETH9i(weth).deposit{value: buyEth}();
      uint256 before = IERC20(token).balanceOf(msg.sender);
      swapPool = pool;
      IV3PoolI(pool).swap(msg.sender, !coinIs0, int256(buyEth), coinIs0 ? MAX_SQRT_RATIO - 1 : MIN_SQRT_RATIO + 1, "");
      swapPool = address(0);
      out = IERC20(token).balanceOf(msg.sender) - before;
    }
    require(out >= minTokensOut, "slippage: fewer tokens than the minimum");
    emit Launched(token, pool, msg.sender, name_, symbol_, buyEth, out, id);
  }

  /* the opening buy pays the pool in WETH, and only during launch() */
  function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external { _pay(a0, a1); }
  function pancakeV3SwapCallback(int256 a0, int256 a1, bytes calldata) external { _pay(a0, a1); }
  function _pay(int256 a0, int256 a1) internal {
    require(msg.sender == swapPool && swapPool != address(0), "not our swap");
    uint256 owe = a0 > 0 ? uint256(a0) : uint256(a1);
    require(IWETH9i(weth).transfer(msg.sender, owe), "pay failed");
  }
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
}
