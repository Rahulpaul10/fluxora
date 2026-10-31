// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

uint256 constant FLUXORA_INITIAL_SUPPLY = 1_000_000_000e18;

/// @title FLUXORA governance token
/// @notice One billion FLUX are minted once. No administrator or further minting exists.
/// @dev Delegation activates voting power; checkpoints use Unix timestamps in seconds.
/// @custom:upgrade-strategy Direct, non-upgradeable deployment (no proxy).
/// @dev Code changes require a replacement deployment and migration.
contract FluxoraToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes {
    uint256 public constant INITIAL_SUPPLY = FLUXORA_INITIAL_SUPPLY;
    error ZeroInitialHolder();

    constructor(address initialHolder) ERC20("FLUXORA", "FLUX") ERC20Permit("FLUXORA") {
        if (initialHolder == address(0)) revert ZeroInitialHolder();
        _mint(initialHolder, INITIAL_SUPPLY);
    }

    /// @notice Current governance timepoint in Unix seconds.
    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    /// @notice ERC-6372 timestamp clock description.
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
