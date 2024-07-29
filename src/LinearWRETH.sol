// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import "./WRETH.sol";

/// @author G9 Software Inc.
/// @author Kane Wallmann (Rocket Pool)
/// @notice Extension that provides linear rebasing for the wrETH token.
/// @dev This contract does not try to predict the future rate, but rather linearly rebases the
/// rate over the specified period, causing it to trail behind any rate increases. In the case
/// of a rate drop, the rate will be immediately adjusted to the lower rate.
contract LinearWRETH is WRETH {

    // Rebasing rate info
    uint256 immutable public rebasingPeriod;
    uint256 public lastRate;
    uint256 public oracleRateReachedAt;

    //
    // Constructor
    //

    /// @param _rETH Address for rETH token
    /// @param _oracle Address for the rETH rate oracle
    /// @param _rebasingPeriod The rebasing period in seconds for the oracle price
    constructor(IERC20 _rETH, PriceOracleInterface _oracle, uint256 _rebasingPeriod) WRETH(_rETH, _oracle) {
        rebasingPeriod = _rebasingPeriod;
        lastRate = oracleRate;
        oracleRateReachedAt = block.timestamp;
    }

    //
    // Rebasing function overrides
    //

    /// @dev Calculates the current interpolated exchange rate
    function rate() public view override returns (uint256) {
        if (block.timestamp >= oracleRateReachedAt) {
            return oracleRate;
        }
        return oracleRate - (oracleRate - lastRate) * (oracleRateReachedAt - block.timestamp) / rebasingPeriod;
    }

    /// @notice Retrieves the current rETH rate from oracle and rebases balances and supply
    /// @dev If rebasing up, the rebasing period will be applied. If down, the change will be immediate.
    function rebase() external override {
        uint256 newRate = oracle.rate();
        // Nothing to do
        if (newRate == oracleRate) {
            return;
        }
        require(newRate != 0);
        // Emit event
        emit Rebase(oracleRate, newRate);
        // Update the rate
        lastRate = rate();
        oracleRate = newRate;
        oracleRateReachedAt = block.timestamp + (oracleRate > lastRate ? rebasingPeriod : 0);
    }

}
