// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title STRATA Token (STRT)
/// @notice Demo-grade ERC-20 used to settle Wi-Fi sessions in the STRATA
///         host node escrow. Adds:
///         - rate-limited public faucet (1000 STRT per address per 24h)
///         - owner-gated mint
///         - pause that gates BOTH faucet and transfers
/// @dev Burnable for hygiene tests. Not upgradeable; demo only.
contract StrataToken is ERC20, ERC20Burnable, Ownable, Pausable {
    uint256 public constant FAUCET_AMOUNT = 1_000 * 10 ** 18;
    uint256 public constant FAUCET_COOLDOWN = 24 hours;

    mapping(address => uint256) public lastFaucetClaim;

    error FaucetCooldown(uint256 remainingSeconds);

    event FaucetClaim(address indexed claimant, uint256 amount, uint256 timestamp);

    constructor(uint256 initialSupply, address initialOwner)
        ERC20("STRATA Token", "STRT")
        Ownable(initialOwner) // reverts OwnableInvalidOwner on address(0)
    {
        if (initialSupply > 0) {
            _mint(initialOwner, initialSupply);
        }
    }

    /// @notice Owner-only mint. Used to seed test balances.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Public, rate-limited faucet so wallets bootstrapping into the
    ///         demo can grab STRT without bothering the deployer.
    function faucet() external whenNotPaused {
        uint256 last = lastFaucetClaim[msg.sender];
        if (last != 0) {
            uint256 unlockAt = last + FAUCET_COOLDOWN;
            if (block.timestamp < unlockAt) {
                revert FaucetCooldown(unlockAt - block.timestamp);
            }
        }
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaim(msg.sender, FAUCET_AMOUNT, block.timestamp);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev OZ v5 hook. Intercepting here gates mint, burn, and transfer
    ///      symmetrically.
    function _update(address from, address to, uint256 value)
        internal
        override
        whenNotPaused
    {
        super._update(from, to, value);
    }
}
