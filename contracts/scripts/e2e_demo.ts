import { ethers, network } from "hardhat";

const SESSION_AMOUNT = ethers.parseEther("5"); // 5 STRT
const QUOTA_BYTES = 5n * 1024n * 1024n * 1024n; // 5 GiB
const CONSUMED_BYTES = 3n * 1024n * 1024n * 1024n; // 3 GiB → host gets 3 STRT

/// Phase E end-to-end demo:
///   deployer → mints 1000 STRT to guest
///   guest    → approves SessionEscrow for 5 STRT, calls openSession
///   host     → signs a receipt for 3 GiB / 5 GiB
///   anyone   → calls closeSession; host receives 3 STRT, guest gets 2 STRT back
///
/// On hardhat network this self-deploys; on amoy it expects deployments/amoy.json
/// to already exist (run scripts/deploy.ts first).
async function main() {
  const [deployer, guest, host] = await ethers.getSigners();
  if (!guest || !host) {
    throw new Error(
      "This script needs at least three signers (deployer, guest, host). On amoy, configure 3 accounts in HardhatUserConfig.networks.amoy.accounts.",
    );
  }

  console.log("\n=== STRATA Phase E e2e demo ===");
  console.log("network :", network.name);
  console.log("deployer:", await deployer.getAddress());
  console.log("guest   :", await guest.getAddress());
  console.log("host    :", await host.getAddress());

  let tokenAddress: string;
  let escrowAddress: string;

  if (network.name === "hardhat" || network.name === "localhost") {
    console.log("\n→ Deploying contracts (local network)...");
    const Token = await ethers.getContractFactory("StrataToken");
    const token = await Token.deploy(ethers.parseEther("10000000"), await deployer.getAddress());
    await token.waitForDeployment();
    tokenAddress = await token.getAddress();

    const Escrow = await ethers.getContractFactory("SessionEscrow");
    const escrow = await Escrow.deploy(tokenAddress, await deployer.getAddress());
    await escrow.waitForDeployment();
    escrowAddress = await escrow.getAddress();
  } else {
    const fs = await import("fs");
    const path = await import("path");
    const recordPath = path.join(__dirname, "..", "deployments", `${network.name}.json`);
    if (!fs.existsSync(recordPath)) {
      throw new Error(`No deployment record at ${recordPath}. Run scripts/deploy.ts first.`);
    }
    const record = JSON.parse(fs.readFileSync(recordPath, "utf-8"));
    tokenAddress = record.strataToken;
    escrowAddress = record.sessionEscrow;
    console.log("\n→ Using deployed StrataToken @", tokenAddress);
    console.log("→ Using deployed SessionEscrow @", escrowAddress);
  }

  const token = await ethers.getContractAt("StrataToken", tokenAddress);
  const escrow = await ethers.getContractAt("SessionEscrow", escrowAddress);

  console.log("\n→ Minting 1000 STRT to guest...");
  await (await token.connect(deployer).mint(await guest.getAddress(), ethers.parseEther("1000"))).wait();
  console.log("   guest balance:", ethers.formatEther(await token.balanceOf(await guest.getAddress())), "STRT");

  console.log("\n→ Guest approves escrow for 5 STRT...");
  await (await token.connect(guest).approve(escrowAddress, SESSION_AMOUNT)).wait();

  // sessionRef from a v4 uuid (12bytes prefix + 20 zero bytes pad → 32 bytes).
  const fakeUuid = "0x" + "ab".repeat(16); // 16 bytes
  const sessionRef = ethers.zeroPadValue(fakeUuid, 32);

  console.log("\n→ Guest opens session (5 STRT, ref", sessionRef, ")...");
  const openTx = await escrow.connect(guest).openSession(await host.getAddress(), SESSION_AMOUNT, sessionRef);
  const openReceipt = await openTx.wait();
  console.log("   tx:", openReceipt!.hash);

  // Pull the SessionOpened event for nice output.
  const openedLog = openReceipt!.logs
    .map((l) => {
      try {
        return escrow.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === "SessionOpened");
  if (openedLog) {
    console.log(
      `   SessionOpened: id=${openedLog.args.sessionId}, ` +
        `amount=${ethers.formatEther(openedLog.args.amount)} STRT, ` +
        `host=${openedLog.args.host}`,
    );
  }
  const sessionId = openedLog!.args.sessionId as bigint;

  console.log("\n→ Host signs receipt (3 GiB / 5 GiB)...");
  const chainId = (await ethers.provider.getNetwork()).chainId;
  const receiptHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["string", "uint256", "address", "uint256", "uint128", "uint128"],
      ["STRATA-SESSION-RECEIPT-V1", chainId, escrowAddress, sessionId, CONSUMED_BYTES, QUOTA_BYTES],
    ),
  );
  const sig = await host.signMessage(ethers.getBytes(receiptHash));
  console.log("   sig:", sig.slice(0, 18), "...");

  console.log("\n→ Closing session (deployer submits)...");
  const closeTx = await escrow.connect(deployer).closeSession(sessionId, CONSUMED_BYTES, QUOTA_BYTES, sig);
  const closeReceipt = await closeTx.wait();
  console.log("   tx:", closeReceipt!.hash);

  const settledLog = closeReceipt!.logs
    .map((l) => {
      try {
        return escrow.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((p) => p?.name === "PaymentSettled");
  if (settledLog) {
    console.log(
      `   PaymentSettled: host got ${ethers.formatEther(settledLog.args.hostPayment)} STRT, ` +
        `guest refunded ${ethers.formatEther(settledLog.args.refund)} STRT`,
    );
  }

  console.log("\n→ Final balances:");
  console.log("   host  :", ethers.formatEther(await token.balanceOf(await host.getAddress())), "STRT");
  console.log("   guest :", ethers.formatEther(await token.balanceOf(await guest.getAddress())), "STRT");

  // Sanity assertions.
  const expectedHost = SESSION_AMOUNT * CONSUMED_BYTES / QUOTA_BYTES;
  const expectedRefund = SESSION_AMOUNT - expectedHost;
  const hostBal = await token.balanceOf(await host.getAddress());
  if (hostBal !== expectedHost) {
    throw new Error(`Host balance mismatch: got ${hostBal}, expected ${expectedHost}`);
  }
  console.log(`\n✓ Demo complete. Host received ${ethers.formatEther(expectedHost)} STRT, ` +
              `guest refunded ${ethers.formatEther(expectedRefund)} STRT.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
