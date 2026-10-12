// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { Fee } from "@layerzerolabs/oft-evm/contracts/Fee.sol";

/// @title Whaletails multichain coin (Robinhood Chain side)
/// @notice A LayerZero OFT that
///   1. mints its chain's half of the supply ONCE, at deployment, to the launch
///      wallet. The matching half is locked on Solana (OFT `lock_supply`), so the
///      coin opens on both chains at once with no bridge wait, and every coin
///      here stays backed 1:1 by coins locked on Solana;
///   2. charges a bridge fee (basis points) on every transfer out of this chain.
///      The fee is paid in the coin, to `feeTo`; only the rest is burned and
///      credited on the other chain.
/// There is no other mint: after the constructor, supply only changes through
/// verified LayerZero messages (credit) and bridging out (burn).
contract WhaletailsOFT is OFT, Fee {
    address public feeTo;

    event FeeToSet(address feeTo);
    event BridgeFeePaid(address indexed from, uint32 indexed dstEid, uint256 fee);

    struct Launch {
        address mintTo;          // receives this chain's half of the supply
        uint256 initialSupply;   // this chain's half, minted once here
        uint16 feeBps;           // bridge fee out of this chain, max 1%
        address feeTo;           // receives the bridge fee
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _owner,
        Launch memory _launch
    ) OFT(_name, _symbol, _lzEndpoint, _owner) Ownable(_owner) {
        require(_launch.feeBps <= 100, "fee above 1%");
        require(_launch.feeTo != address(0) || _launch.feeBps == 0, "fee needs a recipient");
        _mint(_launch.mintTo, _launch.initialSupply);
        defaultFeeBps = _launch.feeBps;
        feeTo = _launch.feeTo;
        emit DefaultFeeBpsSet(_launch.feeBps);
        emit FeeToSet(_launch.feeTo);
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        require(_feeTo != address(0), "zero address");
        feeTo = _feeTo;
        emit FeeToSet(_feeTo);
    }

    /// @dev amountSent = what leaves the sender; amountReceived = what is credited on the
    ///      other chain (after the fee, dust-free). The fee is the difference.
    function _debitView(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal view virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        amountSentLD = _removeDust(_amountLD);
        uint256 fee = getFee(_dstEid, amountSentLD);
        amountReceivedLD = _removeDust(amountSentLD - fee);
        if (amountReceivedLD < _minAmountLD) revert SlippageExceeded(amountReceivedLD, _minAmountLD);
    }

    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        uint256 fee = amountSentLD - amountReceivedLD;
        if (fee > 0) {
            _transfer(_from, feeTo, fee);
            emit BridgeFeePaid(_from, _dstEid, fee);
        }
        _burn(_from, amountReceivedLD);
    }
}
