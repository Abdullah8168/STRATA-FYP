import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

const INITIAL_SUPPLY = ethers.parseEther("10000000"); // 10M STRT
const FAUCET_AMOUNT = ethers.parseEther("1000");
const ONE_DAY = 24 * 60 * 60;

async function deployFixture() {
  const [owner, alice, bob] = await ethers.getSigners();
  const Token = await ethers.getContractFactory("StrataToken");
  const token = await Token.deploy(INITIAL_SUPPLY, owner.address);
  await token.waitForDeployment();
  return { token, owner, alice, bob };
}

describe("StrataToken", () => {
  describe("constructor", () => {
    it("mints initial supply to the owner", async () => {
      const { token, owner } = await loadFixture(deployFixture);
      expect(await token.totalSupply()).to.equal(INITIAL_SUPPLY);
      expect(await token.balanceOf(owner.address)).to.equal(INITIAL_SUPPLY);
      expect(await token.owner()).to.equal(owner.address);
      expect(await token.name()).to.equal("STRATA Token");
      expect(await token.symbol()).to.equal("STRT");
      expect(await token.decimals()).to.equal(18);
    });

    it("rejects a zero owner (Ownable guard)", async () => {
      const Token = await ethers.getContractFactory("StrataToken");
      await expect(Token.deploy(INITIAL_SUPPLY, ethers.ZeroAddress)).to.be.revertedWithCustomError(
        Token,
        "OwnableInvalidOwner",
      );
    });

    it("supports zero initial supply", async () => {
      const [owner] = await ethers.getSigners();
      const Token = await ethers.getContractFactory("StrataToken");
      const token = await Token.deploy(0, owner.address);
      expect(await token.totalSupply()).to.equal(0n);
    });
  });

  describe("mint", () => {
    it("lets the owner mint to anyone", async () => {
      const { token, owner, alice } = await loadFixture(deployFixture);
      await expect(token.connect(owner).mint(alice.address, 100n))
        .to.emit(token, "Transfer")
        .withArgs(ethers.ZeroAddress, alice.address, 100n);
      expect(await token.balanceOf(alice.address)).to.equal(100n);
    });

    it("rejects a non-owner", async () => {
      const { token, alice, bob } = await loadFixture(deployFixture);
      await expect(token.connect(alice).mint(bob.address, 100n))
        .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);
    });
  });

  describe("faucet", () => {
    it("mints FAUCET_AMOUNT to the caller and emits FaucetClaim", async () => {
      const { token, alice } = await loadFixture(deployFixture);
      const tx = await token.connect(alice).faucet();
      await expect(tx).to.emit(token, "FaucetClaim").withArgs(alice.address, FAUCET_AMOUNT, anyUint());
      expect(await token.balanceOf(alice.address)).to.equal(FAUCET_AMOUNT);
    });

    it("rate-limits a second claim within 24h", async () => {
      const { token, alice } = await loadFixture(deployFixture);
      await token.connect(alice).faucet();
      await expect(token.connect(alice).faucet()).to.be.revertedWithCustomError(token, "FaucetCooldown");
    });

    it("re-allows a claim after 24h + 1", async () => {
      const { token, alice } = await loadFixture(deployFixture);
      await token.connect(alice).faucet();
      await time.increase(ONE_DAY + 1);
      await expect(token.connect(alice).faucet()).to.emit(token, "FaucetClaim");
      expect(await token.balanceOf(alice.address)).to.equal(FAUCET_AMOUNT * 2n);
    });

    it("is blocked when paused, and works again after unpause", async () => {
      const { token, owner, alice } = await loadFixture(deployFixture);
      await token.connect(owner).pause();
      await expect(token.connect(alice).faucet()).to.be.revertedWithCustomError(token, "EnforcedPause");
      await token.connect(owner).unpause();
      await expect(token.connect(alice).faucet()).to.emit(token, "FaucetClaim");
    });
  });

  describe("pause / transfers", () => {
    it("blocks transfers while paused", async () => {
      const { token, owner, alice } = await loadFixture(deployFixture);
      await token.connect(owner).transfer(alice.address, 1000n);
      await token.connect(owner).pause();
      await expect(token.connect(alice).transfer(owner.address, 100n)).to.be.revertedWithCustomError(
        token,
        "EnforcedPause",
      );
    });

    it("allows transfers after unpause", async () => {
      const { token, owner, alice } = await loadFixture(deployFixture);
      await token.connect(owner).transfer(alice.address, 1000n);
      await token.connect(owner).pause();
      await token.connect(owner).unpause();
      await expect(token.connect(alice).transfer(owner.address, 100n))
        .to.emit(token, "Transfer")
        .withArgs(alice.address, owner.address, 100n);
    });

    it("rejects pause from a non-owner", async () => {
      const { token, alice } = await loadFixture(deployFixture);
      await expect(token.connect(alice).pause())
        .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);
    });

    it("rejects unpause from a non-owner", async () => {
      const { token, owner, alice } = await loadFixture(deployFixture);
      await token.connect(owner).pause();
      await expect(token.connect(alice).unpause())
        .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);
    });
  });

  describe("burn", () => {
    it("reduces total supply", async () => {
      const { token, owner } = await loadFixture(deployFixture);
      const burnAmount = ethers.parseEther("500");
      await token.connect(owner).burn(burnAmount);
      expect(await token.totalSupply()).to.equal(INITIAL_SUPPLY - burnAmount);
    });
  });
});

// chai-matcher helper since we don't always need a specific timestamp,
// just that it's any uint.
function anyUint() {
  return (value: bigint) => typeof value === "bigint" && value >= 0n;
}
