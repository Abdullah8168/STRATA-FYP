// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SessionEscrow
/// @notice Authoritative on-chain hop for STRATA Wi-Fi sessions. The host
///         node treats SessionOpened events as the only valid signal to
///         admit a guest's MAC to the firewall.
/// @dev Demo-grade. No proxies, no streaming payments, no slashing. The
///      receipt hash binds chainId AND contract address to defeat replay.
contract SessionEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Domain tag for the host's settlement signature. Bumping
    ///         this string is a breaking change.
    string public constant RECEIPT_DOMAIN = "STRATA-SESSION-RECEIPT-V1";

    /// @notice After this elapses with no close, the guest can unilaterally
    ///         dispute and recover their full deposit.
    uint256 public constant DISPUTE_TIMEOUT = 24 hours;

    IERC20 public immutable strataToken;
    address public immutable owner;

    struct Session {
        address guest;
        address host;
        uint128 amount;
        uint64 openedAt;
        bool closed;
        bytes32 sessionRef;
    }

    mapping(uint256 => Session) public sessions;
    mapping(bytes32 => uint256) public sessionRefToId;
    uint256 public nextSessionId;

    bool public paused;

    error ZeroHost();
    error ZeroAmount();
    error ZeroQuota();
    error SessionRefUsed(bytes32 sessionRef);
    error SessionNotFound(uint256 sessionId);
    error SessionAlreadyClosed(uint256 sessionId);
    error InvalidSignature();
    error TooEarlyToDispute(uint256 unlockAt);
    error NotOwner();
    error AlreadyPaused();
    error NotPaused();
    error WhilePaused();

    event SessionOpened(
        uint256 indexed sessionId,
        address indexed guest,
        address indexed host,
        uint128 amount,
        bytes32 sessionRef,
        uint64 openedAt
    );

    event PaymentSettled(
        uint256 indexed sessionId,
        address indexed host,
        uint128 hostPayment,
        address indexed guest,
        uint128 refund
    );

    event SessionDisputed(uint256 indexed sessionId, address indexed guest, uint128 refund);

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    constructor(IERC20 token, address ownerAddress) {
        if (ownerAddress == address(0)) revert NotOwner();
        strataToken = token;
        owner = ownerAddress;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert WhilePaused();
        _;
    }

    /// @notice Lock `amount` STRT into escrow and emit a SessionOpened event
    ///         the host node listens for. Caller (guest) must have approved
    ///         this contract for at least `amount`.
    function openSession(address host, uint128 amount, bytes32 sessionRef)
        external
        whenNotPaused
        returns (uint256 sessionId)
    {
        if (host == address(0)) revert ZeroHost();
        if (amount == 0) revert ZeroAmount();
        if (sessionRefToId[sessionRef] != 0) revert SessionRefUsed(sessionRef);

        // Pull tokens FIRST so a failure here aborts cleanly (no partial state).
        strataToken.safeTransferFrom(msg.sender, address(this), amount);

        unchecked {
            sessionId = ++nextSessionId;
        }

        uint64 openedAt = uint64(block.timestamp);
        sessions[sessionId] = Session({
            guest: msg.sender,
            host: host,
            amount: amount,
            openedAt: openedAt,
            closed: false,
            sessionRef: sessionRef
        });
        sessionRefToId[sessionRef] = sessionId;

        emit SessionOpened(sessionId, msg.sender, host, amount, sessionRef, openedAt);
    }

    /// @notice Settle a session given a host-signed receipt of consumption.
    ///         Anyone can call this; the security comes from the signature.
    /// @param sessionId Escrow session id.
    /// @param bytesConsumed Bytes the meter observed.
    /// @param quotaBytes Quota the guest paid for. Must be > 0.
    /// @param hostSig EIP-191 personal_sign over the receipt hash.
    function closeSession(
        uint256 sessionId,
        uint128 bytesConsumed,
        uint128 quotaBytes,
        bytes calldata hostSig
    ) external nonReentrant {
        Session storage session = sessions[sessionId];
        if (session.host == address(0)) revert SessionNotFound(sessionId);
        if (session.closed) revert SessionAlreadyClosed(sessionId);
        if (quotaBytes == 0) revert ZeroQuota();

        bytes32 receipt = keccak256(
            abi.encode(
                RECEIPT_DOMAIN,
                block.chainid,
                address(this),
                sessionId,
                bytesConsumed,
                quotaBytes
            )
        );
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(receipt);
        address signer = ECDSA.recover(ethHash, hostSig);
        if (signer != session.host) revert InvalidSignature();

        // Cap consumed at quota — host cannot bill the guest for more than
        // they bought.
        uint128 cappedBytes = bytesConsumed > quotaBytes ? quotaBytes : bytesConsumed;
        // payment = amount * cappedBytes / quotaBytes, all uint128 → uint256 safe.
        uint128 payment = uint128((uint256(session.amount) * uint256(cappedBytes)) / uint256(quotaBytes));
        uint128 refund = session.amount - payment;

        // CEI: mark closed BEFORE transferring tokens.
        session.closed = true;

        if (payment > 0) {
            strataToken.safeTransfer(session.host, payment);
        }
        if (refund > 0) {
            strataToken.safeTransfer(session.guest, refund);
        }

        emit PaymentSettled(sessionId, session.host, payment, session.guest, refund);
    }

    /// @notice Guest's escape hatch. After 24h with no settlement, the guest
    ///         can unilaterally claw back their full deposit. Available
    ///         even when paused so funds are never stuck.
    function disputeSession(uint256 sessionId) external nonReentrant {
        Session storage session = sessions[sessionId];
        if (session.host == address(0)) revert SessionNotFound(sessionId);
        if (session.closed) revert SessionAlreadyClosed(sessionId);

        uint256 unlockAt = uint256(session.openedAt) + DISPUTE_TIMEOUT;
        if (block.timestamp < unlockAt) revert TooEarlyToDispute(unlockAt);

        uint128 refund = session.amount;
        session.closed = true;

        strataToken.safeTransfer(session.guest, refund);
        emit SessionDisputed(sessionId, session.guest, refund);
    }

    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Helper that mirrors the on-chain receipt hashing so off-chain
    ///         signers (host node, tests, the Flutter app) can build the
    ///         exact bytes the contract will recover from.
    function receiptHash(
        uint256 sessionId,
        uint128 bytesConsumed,
        uint128 quotaBytes
    ) external view returns (bytes32) {
        return keccak256(
            abi.encode(
                RECEIPT_DOMAIN,
                block.chainid,
                address(this),
                sessionId,
                bytesConsumed,
                quotaBytes
            )
        );
    }
}
