import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import type { Signer } from "ethers";

const INITIAL_SUPPLY = ethers.parseEther("10000000");
const SESSION_AMOUNT = ethers.parseEther("5"); // 5 STRT
const QUOTA = 5n * 1024n * 1024n * 1024n; // 5 GiB
const HALF_QUOTA = QUOTA / 2n;
const ONE_DAY = 24 * 60 * 60;

const REF_ZERO = ethers.zeroPadValue("0x01", 32);
const REF_ONE = ethers.zeroPadValue("0x02", 32);

async function deployFixture() {
  const [deployer, guest, host, attacker] = await ethers.getSigners();
  const Token = await ethers.getContractFactory("StrataToken");
  const token = await Token.deploy(INITIAL_SUPPLY, deployer.address);
  await token.waitForDeployment();

  const Escrow = await ethers.getContractFactory("SessionEscrow");
  const escrow = await Escrow.deploy(await token.getAddress(), deployer.address);
  await escrow.waitForDeployment();

  // Fund guest with enough STRT to run all tests.
  await token.connect(deployer).transfer(guest.address, ethers.parseEther("1000"));

  return { token, escrow, deployer, guest, host, attacker };
}

/// Helper that builds + signs the receipt the way the contract expects.
async function signReceipt(
  signer: Signer,
  escrowAddress: string,
  chainId: bigint,
  sessionId: bigint,
  bytesConsumed: bigint,
  quotaBytes: bigint,
): Promise<string> {
  const receipt = ethers.AbiCoder.defaultAbiCoder().encode(
    ["string", "uint256", "address", "uint256", "uint128", "uint128"],
    ["STRATA-SESSION-RECEIPT-V1", chainId, escrowAddress, sessionId, bytesConsumed, quotaBytes],
  );
  const receiptHash = ethers.keccak256(receipt);
  return signer.signMessage(ethers.getBytes(receiptHash));
}

async function openHappyPath(
  token: any,
  escrow: any,
  guest: Signer,
  host: Signer,
  amount: bigint,
  sessionRef: string,
) {
  const escrowAddr = await escrow.getAddress();
  await token.connect(guest).approve(escrowAddr, amount);
  return escrow
    .connect(guest)
    .openSession(await host.getAddress(), amount, sessionRef);
}

describe("SessionEscrow", () => {
  describe("openSession", () => {
    it("transfers tokens in, stores session, emits indexed event", async () => {
      const { token, escrow, guest, host } = await loadFixture(deployFixture);
      const escrowAddr = await escrow.getAddress();

      const tx = await openHappyPath(token, escrow, guest, host, SESSION_AMOUNT, REF_ZERO);
      const block = await ethers.provider.getBlock(
        (await tx.wait())!.blockNumber!,
      );

      await expect(tx)
        .to.emit(escrow, "SessionOpened")
        .withArgs(1n, await guest.getAddress(), await host.getAddress(), SESSION_AMOUNT, REF_ZERO, block!.timestamp);

      expect(await token.balanceOf(escrowAddr)).to.equal(SESSION_AMOUNT);

      const stored = await escrow.sessions(1n);
      expect(stored.guest).to.equal(await guest.getAddress());
      expect(stored.host).to.equal(await host.getAddress());
      expect(stored.amount).to.equal(SESSION_AMOUNT);
      expect(stored.closed).to.equal(false);
      expect(stored.sessionRef).to.equal(REF_ZERO);
      expect(await escrow.sessionRefToId(REF_ZERO)).to.equal(1n);
    });

    it("rejects zero host", async () => {
      const { token, escrow, guest } = await loadFixture(deployFixture);
      await token.connect(guest).approve(await escrow.getAddress(), SESSION_AMOUNT);
      await expect(
        escrow.connect(guest).openSession(ethers.ZeroAddress, SESSION_AMOUNT, REF_ZERO),
      ).to.be.revertedWithCustomError(escrow, "ZeroHost");
    });

    it("rejects zero amount", async () => {
      const { escrow, guest, host } = await loadFixture(deployFixture);
      await expect(
        escrow.connect(guest).openSession(await host.getAddress(), 0n, REF_ZERO),
      ).to.be.revertedWithCustomError(escrow, "ZeroAmount");
    });

    it("rejects reused sessionRef", async () => {
      const { token, escrow, guest, host } = await loadFixture(deployFixture);
      await openHappyPath(token, escrow, guest, host, SESSION_AMOUNT, REF_ZERO);
      await token.connect(guest).approve(await escrow.getAddress(), SESSION_AMOUNT);
      await expect(
        escrow.connect(guest).openSession(await host.getAddress(), SESSION_AMOUNT, REF_ZERO),
      )
        .to.be.revertedWithCustomError(escrow, "SessionRefUsed")
        .withArgs(REF_ZERO);
    });

    it("is blocked while paused", async () => {
      const { token, escrow, deployer, guest, host } = await loadFixture(deployFixture);
      await escrow.connect(deployer).pause();
      await token.connect(guest).approve(await escrow.getAddress(), SESSION_AMOUNT);
      await expect(
        escrow.connect(guest).openSession(await host.getAddress(), SESSION_AMOUNT, REF_ZERO),
      ).to.be.revertedWithCustomError(escrow, "WhilePaused");
    });
  });

  describe("closeSession", () => {
    async function openedFixture() {
      const base = await loadFixture(deployFixture);
      await openHappyPath(base.token, base.escrow, base.guest, base.host, SESSION_AMOUNT, REF_ZERO);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      return { ...base, chainId, sessionId: 1n };
    }

    it("settles full quota → host gets everything", async () => {
      const { token, escrow, host, guest, sessionId, chainId } = await openedFixture();
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, QUOTA, QUOTA);

      const tx = await escrow.connect(guest).closeSession(sessionId, QUOTA, QUOTA, sig);
      await expect(tx)
        .to.emit(escrow, "PaymentSettled")
        .withArgs(sessionId, await host.getAddress(), SESSION_AMOUNT, await guest.getAddress(), 0n);
      expect(await token.balanceOf(await host.getAddress())).to.equal(SESSION_AMOUNT);
    });

    it("settles half quota → host 2.5 STRT, guest 2.5 STRT", async () => {
      const { token, escrow, host, guest, sessionId, chainId } = await openedFixture();
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, HALF_QUOTA, QUOTA);

      const expectedPayment = SESSION_AMOUNT / 2n;
      const expectedRefund = SESSION_AMOUNT - expectedPayment;
      const guestStartingBalance = await token.balanceOf(await guest.getAddress());

      await expect(escrow.connect(guest).closeSession(sessionId, HALF_QUOTA, QUOTA, sig))
        .to.emit(escrow, "PaymentSettled")
        .withArgs(sessionId, await host.getAddress(), expectedPayment, await guest.getAddress(), expectedRefund);

      expect(await token.balanceOf(await host.getAddress())).to.equal(expectedPayment);
      expect(await token.balanceOf(await guest.getAddress())).to.equal(guestStartingBalance + expectedRefund);
    });

    it("settles zero bytes → guest gets full refund", async () => {
      const { token, escrow, host, guest, sessionId, chainId } = await openedFixture();
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, 0n, QUOTA);

      const guestStartingBalance = await token.balanceOf(await guest.getAddress());
      await expect(escrow.connect(guest).closeSession(sessionId, 0n, QUOTA, sig))
        .to.emit(escrow, "PaymentSettled")
        .withArgs(sessionId, await host.getAddress(), 0n, await guest.getAddress(), SESSION_AMOUNT);

      expect(await token.balanceOf(await host.getAddress())).to.equal(0n);
      expect(await token.balanceOf(await guest.getAddress())).to.equal(guestStartingBalance + SESSION_AMOUNT);
    });

    it("caps bytesConsumed at quotaBytes (overage doesn't double-charge)", async () => {
      const { token, escrow, host, guest, sessionId, chainId } = await openedFixture();
      const overage = QUOTA * 2n;
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, overage, QUOTA);

      await expect(escrow.connect(guest).closeSession(sessionId, overage, QUOTA, sig))
        .to.emit(escrow, "PaymentSettled")
        .withArgs(sessionId, await host.getAddress(), SESSION_AMOUNT, await guest.getAddress(), 0n);
    });

    it("rejects zero quotaBytes", async () => {
      const { escrow, guest, sessionId } = await openedFixture();
      // Any random sig — we should fail before signature recovery.
      const fakeSig = "0x" + "00".repeat(65);
      await expect(escrow.connect(guest).closeSession(sessionId, 0n, 0n, fakeSig))
        .to.be.revertedWithCustomError(escrow, "ZeroQuota");
    });

    it("rejects unknown sessionId", async () => {
      const { escrow, guest } = await loadFixture(deployFixture);
      const fakeSig = "0x" + "00".repeat(65);
      await expect(escrow.connect(guest).closeSession(999n, QUOTA, QUOTA, fakeSig))
        .to.be.revertedWithCustomError(escrow, "SessionNotFound")
        .withArgs(999n);
    });

    it("rejects an invalid signer", async () => {
      const { escrow, attacker, guest, sessionId, chainId } = await openedFixture();
      const sig = await signReceipt(attacker, await escrow.getAddress(), chainId, sessionId, QUOTA, QUOTA);
      await expect(escrow.connect(guest).closeSession(sessionId, QUOTA, QUOTA, sig))
        .to.be.revertedWithCustomError(escrow, "InvalidSignature");
    });

    it("rejects replays once closed", async () => {
      const { escrow, host, guest, sessionId, chainId } = await openedFixture();
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, QUOTA, QUOTA);
      await escrow.connect(guest).closeSession(sessionId, QUOTA, QUOTA, sig);
      await expect(escrow.connect(guest).closeSession(sessionId, QUOTA, QUOTA, sig))
        .to.be.revertedWithCustomError(escrow, "SessionAlreadyClosed")
        .withArgs(sessionId);
    });

    it("settles even while paused (funds are never stuck)", async () => {
      const { escrow, host, guest, deployer, sessionId, chainId } = await openedFixture();
      await escrow.connect(deployer).pause();
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, QUOTA, QUOTA);
      await expect(escrow.connect(guest).closeSession(sessionId, QUOTA, QUOTA, sig)).to.emit(
        escrow,
        "PaymentSettled",
      );
    });

    it("binds chainId — same sig is invalid on a different chain", async () => {
      const { escrow, host, sessionId } = await openedFixture();
      // Use a wrong chainId to forge the signature → ECDSA recovers a
      // signer that is NOT the host.
      const wrongChainId = 1n;
      const sig = await signReceipt(host, await escrow.getAddress(), wrongChainId, sessionId, QUOTA, QUOTA);
      await expect(escrow.closeSession(sessionId, QUOTA, QUOTA, sig)).to.be.revertedWithCustomError(
        escrow,
        "InvalidSignature",
      );
    });

    it("binds contract address — receipt for one escrow does not work in another", async () => {
      const { token, escrow, deployer, host, guest, sessionId, chainId } = await openedFixture();

      // Deploy a SECOND escrow with the same token + owner.
      const Escrow = await ethers.getContractFactory("SessionEscrow");
      const escrow2 = await Escrow.deploy(await token.getAddress(), deployer.address);
      await escrow2.waitForDeployment();

      // Open an identical session (id 1) on escrow2.
      await token.connect(guest).approve(await escrow2.getAddress(), SESSION_AMOUNT);
      await escrow2.connect(guest).openSession(await host.getAddress(), SESSION_AMOUNT, REF_ONE);

      // Host signs a receipt for escrow1.
      const sigForEscrow1 = await signReceipt(
        host,
        await escrow.getAddress(),
        chainId,
        sessionId,
        QUOTA,
        QUOTA,
      );

      // Replaying that signature on escrow2 must fail (contract address is
      // mixed into the hash, so the recovered signer is wrong).
      await expect(escrow2.closeSession(1n, QUOTA, QUOTA, sigForEscrow1)).to.be.revertedWithCustomError(
        escrow2,
        "InvalidSignature",
      );
    });
  });

  describe("disputeSession", () => {
    async function openedFixture() {
      const base = await loadFixture(deployFixture);
      await openHappyPath(base.token, base.escrow, base.guest, base.host, SESSION_AMOUNT, REF_ZERO);
      return { ...base, sessionId: 1n };
    }

    it("rejects before timeout", async () => {
      const { escrow, guest, sessionId } = await openedFixture();
      await expect(escrow.connect(guest).disputeSession(sessionId)).to.be.revertedWithCustomError(
        escrow,
        "TooEarlyToDispute",
      );
    });

    it("refunds the guest after timeout", async () => {
      const { token, escrow, guest, sessionId } = await openedFixture();
      const guestBefore = await token.balanceOf(await guest.getAddress());
      await time.increase(ONE_DAY + 1);
      await expect(escrow.disputeSession(sessionId))
        .to.emit(escrow, "SessionDisputed")
        .withArgs(sessionId, await guest.getAddress(), SESSION_AMOUNT);
      const guestAfter = await token.balanceOf(await guest.getAddress());
      expect(guestAfter - guestBefore).to.equal(SESSION_AMOUNT);
    });

    it("rejects disputes on closed sessions", async () => {
      const { escrow, host, guest, sessionId } = await openedFixture();
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const sig = await signReceipt(host, await escrow.getAddress(), chainId, sessionId, QUOTA, QUOTA);
      await escrow.connect(guest).closeSession(sessionId, QUOTA, QUOTA, sig);
      await time.increase(ONE_DAY + 1);
      await expect(escrow.connect(guest).disputeSession(sessionId)).to.be.revertedWithCustomError(
        escrow,
        "SessionAlreadyClosed",
      );
    });

    it("rejects disputes on unknown sessions", async () => {
      const { escrow } = await loadFixture(deployFixture);
      await expect(escrow.disputeSession(999n))
        .to.be.revertedWithCustomError(escrow, "SessionNotFound")
        .withArgs(999n);
    });

    it("works while paused", async () => {
      const { escrow, deployer, guest, sessionId } = await openedFixture();
      await escrow.connect(deployer).pause();
      await time.increase(ONE_DAY + 1);
      await expect(escrow.connect(guest).disputeSession(sessionId)).to.emit(escrow, "SessionDisputed");
    });
  });

  describe("pause / unpause", () => {
    it("only owner can pause", async () => {
      const { escrow, attacker } = await loadFixture(deployFixture);
      await expect(escrow.connect(attacker).pause()).to.be.revertedWithCustomError(escrow, "NotOwner");
    });

    it("only owner can unpause", async () => {
      const { escrow, deployer, attacker } = await loadFixture(deployFixture);
      await escrow.connect(deployer).pause();
      await expect(escrow.connect(attacker).unpause()).to.be.revertedWithCustomError(escrow, "NotOwner");
    });

    it("rejects double-pause and unpause-when-not-paused", async () => {
      const { escrow, deployer } = await loadFixture(deployFixture);
      await expect(escrow.connect(deployer).unpause()).to.be.revertedWithCustomError(escrow, "NotPaused");
      await escrow.connect(deployer).pause();
      await expect(escrow.connect(deployer).pause()).to.be.revertedWithCustomError(escrow, "AlreadyPaused");
      await expect(escrow.connect(deployer).unpause()).to.emit(escrow, "Unpaused");
    });

    it("emits Paused/Unpaused events", async () => {
      const { escrow, deployer } = await loadFixture(deployFixture);
      await expect(escrow.connect(deployer).pause()).to.emit(escrow, "Paused").withArgs(deployer.address);
    });
  });

  describe("constructor", () => {
    it("rejects zero owner", async () => {
      const Token = await ethers.getContractFactory("StrataToken");
      const [owner] = await ethers.getSigners();
      const token = await Token.deploy(INITIAL_SUPPLY, owner.address);
      const Escrow = await ethers.getContractFactory("SessionEscrow");
      await expect(Escrow.deploy(await token.getAddress(), ethers.ZeroAddress)).to.be.revertedWithCustomError(
        Escrow,
        "NotOwner",
      );
    });
  });

  describe("receiptHash helper", () => {
    it("matches the on-chain hash used in closeSession", async () => {
      const { escrow } = await loadFixture(deployFixture);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const sessionId = 7n;
      const onChain = await escrow.receiptHash(sessionId, 1n, 2n);

      const expected = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["string", "uint256", "address", "uint256", "uint128", "uint128"],
          ["STRATA-SESSION-RECEIPT-V1", chainId, await escrow.getAddress(), sessionId, 1n, 2n],
        ),
      );
      expect(onChain).to.equal(expected);
    });
  });
});
