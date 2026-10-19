// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/* Whale Tail bonding curve for every EVM chain (first built for Robinhood Chain, 2026-10-16; generalised 2026-10-18).
   "ETH" below means the chain's native coin
   (BNB, POL, AVAX, ...) and WETH its wrapped form. The DEX is any faithful Uniswap v3 or PancakeSwap v3 deployment,
   described per chain by the Dex struct.
   - The whole 1,000,000,000 supply is minted to the coin's curve. Buys and sells trade against ETH on a constant
     product with a phantom ETH reserve, which sets the opening price without a deposit.
   - Part of the supply is never sellable: it stays for the pool. When the sellable part is gone the curve is ready
     to graduate, normally inside the buy that empties it; if that fails anyone can call graduate().
   - Graduation seeds a full-range Uniswap v3 position at exactly the curve's final price with all the ETH, burns the
     tokens that price does not need (so there is no price drop), and locks the position in the Whale Tail locker,
     which splits pool fees 50/50 between the creator and the platform. Nobody can withdraw it.
   - Before graduation the token refuses transfers into the four Uniswap v3 pool addresses it could graduate to, so
     nobody can seed the pool first at a wrong price.
   - Fees: 1% on buys (from the input) and sells (from the output), plus an opening snipe tax on buys that falls from
     99% to zero within 5 seconds. All of it is split 50/50 creator/platform and claimed with claimFees().
   - No owner, no admin, no withdrawal of curve funds. If graduation is impossible for a day, sells reopen. */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IWETH9 { function deposit() external payable; function approve(address, uint256) external returns (bool); function transfer(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IV3Pool {
  function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);   // uint32: PancakeSwap's feeProtocol (Uniswap's uint8 decodes the same)
  function liquidity() external view returns (uint128);
  function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256, int256);
}
interface INPM {
  struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired;
    uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }
  function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96) external payable returns (address);
  function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
  function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

interface IV2Factory { function getPair(address, address) external view returns (address); function createPair(address, address) external returns (address); }
interface IV2Pair { function mint(address to) external returns (uint256); function getReserves() external view returns (uint112, uint112, uint32); }

/// One chain's DEX. Uniswap v3: poolDeployer is the factory, initCodeHash 0xe34f...8b54. PancakeSwap v3: its PoolDeployer.
/// Uniswap-v2 style (2026-10-18): poolDeployer = 0, v3Factory = the v2 factory, npm and locker unused (LP is burned).
struct Dex { address weth; address npm; address v3Factory; address poolDeployer; bytes32 initCodeHash; address locker; }

library V3 {
  function poolAddress(address deployer, bytes32 initCodeHash, address a, address b, uint24 fee) internal pure returns (address) {
    (address t0, address t1) = a < b ? (a, b) : (b, a);
    return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, keccak256(abi.encode(t0, t1, fee)), initCodeHash)))));
  }
  function spacing(uint24 fee) internal pure returns (int24) {
    return fee == 10000 ? int24(200) : fee == 3000 ? int24(60) : fee == 2500 ? int24(50) : fee == 500 ? int24(10) : int24(1);
  }
}

contract WTCurveToken is ERC20 {
  uint256 public constant SUPPLY = 1_000_000_000 ether;
  address public immutable curve;
  bool public graduated;
  mapping(address => bool) public poolBlocked;          // the Uniswap v3 pools it could graduate to, until it does
  address public immutable v2Factory;                   // v2 chains: the pair is looked up live (it may not exist yet)
  address public immutable weth;

  constructor(string memory name_, string memory symbol_, address curve_, Dex memory dex) ERC20(name_, symbol_) {
    curve = curve_;
    weth = dex.weth;
    v2Factory = dex.poolDeployer == address(0) ? dex.v3Factory : address(0);
    uint24[5] memory fees = [uint24(100), 500, 2500, 3000, 10000];  // every tier on Uniswap or Pancake; a tier a DEX lacks is harmless
    if (dex.poolDeployer != address(0)) for (uint256 i = 0; i < 5; i++) poolBlocked[V3.poolAddress(dex.poolDeployer, dex.initCodeHash, address(this), dex.weth, fees[i])] = true;
    _mint(curve_, SUPPLY);
  }
  function markGraduated() external { require(msg.sender == curve, "only the curve"); graduated = true; }
  function _beforeTokenTransfer(address from, address to, uint256) internal view override {
    if (!graduated && from != curve && (poolBlocked[to] || (v2Factory != address(0) && to != address(0) && to == IV2Factory(v2Factory).getPair(address(this), weth))))
      revert("the pool opens at graduation");
  }
}

contract WTCurve is ReentrancyGuard {
  uint256 public constant FEE_BPS = 100;                // 1% on buys and sells
  uint256 public constant BPS = 10_000;
  address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

  WTCurveToken public immutable token;
  address public immutable factory;
  address public immutable creator;
  address public immutable platform;
  uint256 public immutable phantom;                     // virtual ETH reserve: sets the opening price
  uint256 public immutable threshold;                   // ETH taken in when the curve sells out
  uint256 public immutable reservedForPool;             // tokens that stay on the curve: SUPPLY * phantom / (phantom + threshold)
  uint256 public immutable launchedAt;
  address public immutable weth;
  address public immutable npm;
  address public immutable v3Factory;
  address public immutable locker;
  bool public immutable isV2;                           // graduates to a Uniswap-v2 style pair, LP burned

  uint256 public realQuote;                             // real ETH taken in by the curve (fees excluded)
  uint256 public tokenReserve;                          // tokens on the curve
  uint256 public creatorFees;
  uint256 public platformFees;
  bool public initialBought;
  bool public readyToGraduate;
  uint256 public readyAt;
  bool public graduated;
  address public pool;
  uint256 public positionId;
  address private swapPool;                             // the pool allowed to call back during a price fix

  event Buy(address indexed buyer, address indexed recipient, uint256 ethIn, uint256 fee, uint256 snipeTax, uint256 tokensOut, uint256 realQuote, uint256 tokenReserve);
  event Sell(address indexed seller, address indexed recipient, uint256 tokensIn, uint256 ethOut, uint256 fee, uint256 realQuote, uint256 tokenReserve);
  event ReadyToGraduate(uint256 realQuote);
  event Graduated(address indexed pool, uint256 positionId, uint256 ethIn, uint256 tokensIn, uint256 tokensBurned, uint24 fee);
  event AutoGraduationFailed(bytes reason);
  event Reopened();
  event FeesClaimed(uint256 toCreator, uint256 toPlatform);

  constructor(string memory name_, string memory symbol_, address creator_, address platform_, uint256 phantom_, uint256 threshold_,
              Dex memory dex, address factory_) {
    require(creator_ != address(0) && platform_ != address(0) && phantom_ > 0 && threshold_ > 0, "bad config");
    factory = factory_;
    creator = creator_; platform = platform_; phantom = phantom_; threshold = threshold_;
    weth = dex.weth; npm = dex.npm; v3Factory = dex.v3Factory; locker = dex.locker;
    isV2 = dex.poolDeployer == address(0);
    launchedAt = block.timestamp;
    token = new WTCurveToken(name_, symbol_, address(this), dex);
    tokenReserve = 1_000_000_000 ether;
    reservedForPool = Math.mulDiv(1_000_000_000 ether, phantom_, phantom_ + threshold_);
  }

  /* ── views ─────────────────────────────────────────────────────────────── */
  function sellableTokens() public view returns (uint256) { return tokenReserve > reservedForPool ? tokenReserve - reservedForPool : 0; }
  function progressBps() external view returns (uint256) { return graduated || readyToGraduate ? BPS : Math.min(BPS, realQuote * BPS / threshold); }
  /* the opening snipe tax on buys, by whole seconds since launch: 99%, 25%, 3%, 1%, 0.5%, then none */
  function currentSnipeTaxBps() public view returns (uint256) {
    uint256 t = block.timestamp - launchedAt;
    if (t == 0) return 9900; if (t == 1) return 2500; if (t == 2) return 300; if (t == 3) return 100; if (t == 4) return 50;
    return 0;
  }
  function priceWeiPerToken() external view returns (uint256) { return Math.mulDiv(phantom + realQuote, 1 ether, tokenReserve); }
  function quoteBuy(uint256 ethIn) external view returns (uint256 tokensOut) {
    (,, uint256 net) = _split(ethIn, currentSnipeTaxBps());
    tokensOut = Math.min(Math.mulDiv(net, tokenReserve, phantom + realQuote + net), sellableTokens());
  }
  function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut) {
    uint256 gross = Math.min(Math.mulDiv(tokensIn, phantom + realQuote, tokenReserve + tokensIn), realQuote);
    ethOut = gross - gross * FEE_BPS / BPS;
  }

  /* ── trading ───────────────────────────────────────────────────────────── */
  function _split(uint256 gross, uint256 taxBps) internal pure returns (uint256 fee, uint256 tax, uint256 net) {
    fee = gross * FEE_BPS / BPS;
    tax = (gross - fee) * taxBps / BPS;
    net = gross - fee - tax;
  }
  function _accrue(uint256 amount) internal {
    uint256 half = amount / 2;
    platformFees += half;
    creatorFees += amount - half;
  }

  /// The creator's first buy, made by the factory inside the launch transaction: no snipe tax.
  function initialBuy(address recipient, uint256 minTokensOut) external payable nonReentrant returns (uint256) {
    require(msg.sender == factory && !initialBought, "only the launch");
    initialBought = true;
    return _buy(recipient, minTokensOut, 0);
  }
  function buy(address recipient, uint256 minTokensOut) external payable nonReentrant returns (uint256) {
    return _buy(recipient, minTokensOut, currentSnipeTaxBps());
  }

  function _buy(address recipient, uint256 minTokensOut, uint256 taxBps) internal returns (uint256 out) {
    require(!graduated && !readyToGraduate, "the curve is closed: trade on Uniswap");
    require(msg.value > 0 && recipient != address(0), "nothing to buy");
    uint256 gross = msg.value;
    (uint256 fee, uint256 tax, uint256 net) = _split(gross, taxBps);
    out = Math.mulDiv(net, tokenReserve, phantom + realQuote + net);
    uint256 sellable = sellableTokens();
    uint256 refund = 0;
    if (out >= sellable) {
      /* the last buy: take only what empties the curve and refund the rest */
      out = sellable;
      uint256 netUsed = Math.mulDiv(phantom + realQuote, out, tokenReserve - out, Math.Rounding.Up);
      uint256 grossUsed = Math.mulDiv(netUsed, BPS * BPS, (BPS - FEE_BPS) * (BPS - taxBps), Math.Rounding.Up);
      if (grossUsed < gross) {
        refund = gross - grossUsed;
        (fee, tax, net) = _split(grossUsed, taxBps);
      }
    }
    require(out > 0 && out >= minTokensOut, "slippage: fewer tokens than the minimum");
    tokenReserve -= out;
    realQuote += net;
    _accrue(fee + tax);
    emit Buy(msg.sender, recipient, gross - refund, fee, tax, out, realQuote, tokenReserve);
    require(token.transfer(recipient, out), "token transfer failed");
    if (refund > 0) {
      /* the launch buy arrives via the factory, which cannot take ETH back: refund the creator directly */
      (bool ok, ) = (msg.sender == factory ? recipient : msg.sender).call{value: refund}("");
      require(ok, "refund failed");
    }
    if (sellableTokens() == 0) {
      readyToGraduate = true; readyAt = block.timestamp;
      emit ReadyToGraduate(realQuote);
      try this.graduateFromCurve() {} catch (bytes memory reason) { emit AutoGraduationFailed(reason); }
    }
  }

  function sell(uint256 tokensIn, uint256 minEthOut, address recipient) external nonReentrant returns (uint256 ethOut) {
    require(!graduated && !readyToGraduate, "the curve is closed: trade on Uniswap");
    require(tokensIn > 0 && recipient != address(0), "nothing to sell");
    uint256 gross = Math.min(Math.mulDiv(tokensIn, phantom + realQuote, tokenReserve + tokensIn), realQuote);
    uint256 fee = gross * FEE_BPS / BPS;
    ethOut = gross - fee;
    require(ethOut > 0 && ethOut >= minEthOut, "slippage: less ETH than the minimum");
    tokenReserve += tokensIn;
    realQuote -= gross;
    _accrue(fee);
    emit Sell(msg.sender, recipient, tokensIn, ethOut, fee, realQuote, tokenReserve);
    require(token.transferFrom(msg.sender, address(this), tokensIn), "token transfer failed");
    (bool ok, ) = recipient.call{value: ethOut}("");
    require(ok, "ETH transfer failed");
  }

  /// Fees to the creator and the platform. Anyone may call; a failed send just stays for next time.
  function claimFees() external nonReentrant {
    uint256 c = creatorFees; uint256 p = platformFees;
    uint256 sentC = 0; uint256 sentP = 0;
    if (c > 0) { creatorFees = 0; (bool ok, ) = creator.call{value: c}(""); if (ok) sentC = c; else creatorFees = c; }
    if (p > 0) { platformFees = 0; (bool ok2, ) = platform.call{value: p}(""); if (ok2) sentP = p; else platformFees = p; }
    emit FeesClaimed(sentC, sentP);
  }

  /// If graduation has been impossible for a day, the curve reopens for sells so nobody is stuck.
  function reopenIfStuck() external {
    require(readyToGraduate && !graduated && block.timestamp > readyAt + 1 days, "not stuck");
    readyToGraduate = false;
    emit Reopened();
  }

  /* ── graduation ────────────────────────────────────────────────────────── */
  function graduate() external nonReentrant { _graduate(); }
  /// Only the curve itself, from the buy that empties it (that buy already holds the reentrancy lock).
  function graduateFromCurve() external { require(msg.sender == address(this), "only the curve"); _graduate(); }

  function _graduate() internal {
    require(readyToGraduate && !graduated, "not ready to graduate");
    uint256 ethIn = realQuote;
    /* the pool gets every ETH and the tokens that hold the curve's final price; the rest is burned */
    uint256 tokensIn = Math.mulDiv(ethIn, tokenReserve, phantom + realQuote);
    if (isV2) { _graduateV2(ethIn, tokensIn); return; }
    uint24[4] memory tiers = [uint24(10000), 3000, 2500, 500];       // 3000 is Uniswap's, 2500 Pancake's; a missing tier fails and is skipped
    address chosen = address(0); uint24 fee = 0;
    for (uint256 i = 0; i < 4 && chosen == address(0); i++) {
      try this.preparePool(tiers[i], tokensIn, ethIn) returns (address p) { chosen = p; fee = tiers[i]; } catch {}
    }
    require(chosen != address(0), "no Uniswap pool could be opened at the launch price");
    graduated = true;
    pool = chosen;
    token.markGraduated();
    IWETH9(weth).deposit{value: ethIn}();
    (address t0, address t1) = address(token) < weth ? (address(token), weth) : (weth, address(token));
    (uint256 a0, uint256 a1) = address(token) < weth ? (tokensIn, ethIn) : (ethIn, tokensIn);
    require(token.approve(npm, tokensIn) && IWETH9(weth).approve(npm, ethIn), "approve failed");
    int24 sp = V3.spacing(fee);
    int24 maxTick = (int24(887272) / sp) * sp;
    (uint256 id, , uint256 used0, uint256 used1) = INPM(npm).mint(INPM.MintParams({ token0: t0, token1: t1, fee: fee,
      tickLower: -maxTick, tickUpper: maxTick, amount0Desired: a0, amount1Desired: a1,
      amount0Min: a0 * 99 / 100, amount1Min: a1 * 99 / 100, recipient: address(this), deadline: block.timestamp }));
    positionId = id;
    INPM(npm).safeTransferFrom(address(this), locker, id, abi.encode(creator));
    uint256 usedTokens = address(token) < weth ? used0 : used1;
    uint256 burned = token.balanceOf(address(this));
    if (burned > 0) require(token.transfer(DEAD, burned), "burn failed");
    uint256 wethLeft = IWETH9(weth).balanceOf(address(this));
    if (wethLeft > 0) require(IWETH9(weth).transfer(platform, wethLeft), "dust transfer failed");
    tokenReserve = 0;
    emit Graduated(chosen, id, ethIn, usedTokens, burned, fee);
  }

  /// v2: the pair gets every ETH and the tokens that hold the curve's final price; the LP tokens are burned (locked forever).
  /// A pair created early can only hold donated WETH (the coin cannot be sent in before graduation): that just raises the
  /// opening price a little, paid by whoever donated.
  function _graduateV2(uint256 ethIn, uint256 tokensIn) internal {
    address pair = IV2Factory(v3Factory).getPair(address(token), weth);
    if (pair == address(0)) pair = IV2Factory(v3Factory).createPair(address(token), weth);
    graduated = true;
    pool = pair;
    token.markGraduated();
    IWETH9(weth).deposit{value: ethIn}();
    require(token.transfer(pair, tokensIn) && IWETH9(weth).transfer(pair, ethIn), "seed transfer failed");
    positionId = IV2Pair(pair).mint(DEAD);                 // the LP amount, burned
    uint256 burned = token.balanceOf(address(this));
    if (burned > 0) require(token.transfer(DEAD, burned), "burn failed");
    tokenReserve = 0;
    emit Graduated(pair, positionId, ethIn, tokensIn, burned, 0);
  }

  /// Creates the pool, or brings an EMPTY existing one to the launch price; reverts if that tier cannot be used.
  function preparePool(uint24 fee, uint256 tokensIn, uint256 ethIn) external returns (address p) {
    require(msg.sender == address(this), "only the curve");
    (address t0, address t1) = address(token) < weth ? (address(token), weth) : (weth, address(token));
    uint256 amount0 = address(token) < weth ? tokensIn : ethIn;
    uint256 amount1 = address(token) < weth ? ethIn : tokensIn;
    uint160 target = uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
    p = IV3Factory(v3Factory).getPool(t0, t1, fee);
    if (p == address(0)) return INPM(npm).createAndInitializePoolIfNecessary(t0, t1, fee, target);
    (uint160 cur, , , , , , ) = IV3Pool(p).slot0();
    if (_close(cur, target)) return p;
    /* someone created it first at another price: an empty pool's price moves for free; any liquidity in the way makes
       the callback below demand payment, which reverts, and this tier is skipped */
    swapPool = p;
    IV3Pool(p).swap(address(this), target < cur, 1, target, "");
    swapPool = address(0);
    (cur, , , , , , ) = IV3Pool(p).slot0();
    require(_close(cur, target), "pool price could not be set");
  }
  function _close(uint160 a, uint160 b) internal pure returns (bool) {
    uint256 hi = a > b ? a : b; uint256 lo = a > b ? b : a;
    return (hi - lo) * 1000 <= hi;                      // within 0.1% in sqrt price (about 0.2% in price)
  }
  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external view { _priceFixCallback(amount0Delta, amount1Delta); }
  function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external view { _priceFixCallback(amount0Delta, amount1Delta); }
  function _priceFixCallback(int256 amount0Delta, int256 amount1Delta) internal view {
    require(msg.sender == swapPool && swapPool != address(0), "not our price fix");
    require(amount0Delta <= 0 && amount1Delta <= 0, "the pool holds liquidity: not moving it");
  }
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
  receive() external payable { require(msg.sender == weth, "use buy()"); }
}

/// Holds the curve's creation code so the factory stays small.
contract WTCurveDeployer {
  address public immutable factory;
  constructor(address factory_) { factory = factory_; }
  function deploy(string calldata name_, string calldata symbol_, address creator_, address platform_, uint256 phantom_, uint256 threshold_,
                  Dex calldata dex) external returns (address) {
    require(msg.sender == factory, "only the factory");
    return address(new WTCurve(name_, symbol_, creator_, platform_, phantom_, threshold_, dex, factory));
  }
}

contract WTCurveFactory {
  address public owner;
  address public platform;
  address public deployer;
  address public immutable weth;
  address public immutable npm;
  address public immutable v3Factory;
  address public immutable poolDeployer;
  bytes32 public immutable initCodeHash;
  address public immutable locker;
  uint256 public launchFee;
  uint256 public phantom;
  uint256 public threshold;
  mapping(address => address) public curveOf;           // token => curve
  address[] public allTokens;

  event Launched(address indexed token, address indexed curve, address indexed creator, string name, string symbol, uint256 initialBuyEth, uint256 tokensOut);
  event ParamsSet(uint256 launchFee, uint256 phantom, uint256 threshold, address platform);

  constructor(Dex memory dex_, address platform_, uint256 launchFee_, uint256 phantom_, uint256 threshold_) {
    require(dex_.weth != address(0) && dex_.v3Factory != address(0) && (dex_.poolDeployer == address(0) || (dex_.npm != address(0) && dex_.locker != address(0))), "bad dex");
    owner = msg.sender;
    weth = dex_.weth; npm = dex_.npm; v3Factory = dex_.v3Factory; poolDeployer = dex_.poolDeployer; initCodeHash = dex_.initCodeHash; locker = dex_.locker;
    platform = platform_; launchFee = launchFee_; phantom = phantom_; threshold = threshold_;
  }
  modifier onlyOwner() { require(msg.sender == owner, "only the owner"); _; }
  function setDeployer(address d) external onlyOwner { require(deployer == address(0), "already set"); deployer = d; }
  /// Applies to FUTURE launches only: a live curve's numbers are fixed in its own contract.
  function setParams(uint256 launchFee_, uint256 phantom_, uint256 threshold_, address platform_) external onlyOwner {
    require(phantom_ > 0 && threshold_ > 0 && platform_ != address(0), "bad params");
    launchFee = launchFee_; phantom = phantom_; threshold = threshold_; platform = platform_;
    emit ParamsSet(launchFee_, phantom_, threshold_, platform_);
  }
  function setOwner(address o) external onlyOwner { require(o != address(0), "bad owner"); owner = o; }
  function launchCount() external view returns (uint256) { return allTokens.length; }
  function dex() public view returns (Dex memory) { return Dex(weth, npm, v3Factory, poolDeployer, initCodeHash, locker); }

  /// One transaction from the creator's wallet: the coin, its curve, the launch fee, and the creator's first buy.
  function launch(string calldata name_, string calldata symbol_, uint256 minTokensOut) external payable returns (address token, address curve) {
    require(deployer != address(0), "not set up");
    require(bytes(name_).length > 0 && bytes(name_).length <= 32 && bytes(symbol_).length > 0 && bytes(symbol_).length <= 10, "bad name or ticker");
    require(msg.value >= launchFee, "the launch fee is missing");
    curve = WTCurveDeployer(deployer).deploy(name_, symbol_, msg.sender, platform, phantom, threshold, dex());
    token = address(WTCurve(payable(curve)).token());
    curveOf[token] = curve;
    allTokens.push(token);
    if (launchFee > 0) { (bool ok, ) = platform.call{value: launchFee}(""); require(ok, "fee transfer failed"); }
    uint256 buyEth = msg.value - launchFee;
    uint256 out = 0;
    if (buyEth > 0) out = WTCurve(payable(curve)).initialBuy{value: buyEth}(msg.sender, minTokensOut);
    emit Launched(token, curve, msg.sender, name_, symbol_, buyEth, out);
  }
}
