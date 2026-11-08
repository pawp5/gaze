// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/external/IChainlink.sol";

/// @notice Chainlink read with positivity, staleness and L2 sequencer checks.
/// Arbitrum sequencer feed 0xFdB631F5EE196F0ed6FAa767959853A9F217697D (Chainlink docs + on-chain, 2026-11-08).
library OracleGuard {
    error SequencerDown();
    error SequencerGracePeriod();
    error StalePrice(address feed, uint256 updatedAt);
    error InvalidPrice(address feed, int256 answer);

    uint256 internal constant SEQUENCER_GRACE = 1 hours;

    /// @return price answer scaled to 8 decimals
    function read(address feed, address sequencerFeed, uint256 maxAge) internal view returns (uint256 price) {
        if (sequencerFeed != address(0)) {
            (, int256 status, uint256 startedAt,,) = IAggregatorV3(sequencerFeed).latestRoundData();
            if (status != 0) revert SequencerDown();
            if (block.timestamp - startedAt < SEQUENCER_GRACE) revert SequencerGracePeriod();
        }
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(feed, answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StalePrice(feed, updatedAt);
        }
        uint8 d = IAggregatorV3(feed).decimals();
        uint256 a = uint256(answer);
        if (d == 8) return a;
        if (d > 8) return a / (10 ** (d - 8));
        return a * (10 ** (8 - d));
    }
}
