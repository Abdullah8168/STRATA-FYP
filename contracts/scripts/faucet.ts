import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/// Top up an arbitrary address with STRT. If the runner is the token owner,
/// uses mint(); otherwise falls back to the public faucet() (the runner
/// receives the tokens, since faucet pays msg.sender).
///
/// Usage:
///   TARGET=0x.. AMOUNT=500 npx hardhat run scripts/faucet.ts --network amoy
///
/// AMOUNT is in whole STRT (no decimals).
async function main() {
  const target = process.env.TARGET;
  const amountInTokens = process.env.AMOUNT ?? "1000";
  if (!target) {
    console.error("Set TARGET=0x... before running.");
    process.exit(1);
  }
  const amount = ethers.parseEther(amountInTokens);

  const filename = network.name === "amoy" ? "amoy.json" : `${network.name}.json`;
  const recordPath = path.join(__dirname, "..", "deployments", filename);
  if (!fs.existsSync(recordPath)) {
    console.error(`No deployment record at ${recordPath}. Run scripts/deploy.ts first.`);
    process.exit(1);
  }
  const record = JSON.parse(fs.readFileSync(recordPath, "utf-8"));

  const [signer] = await ethers.getSigners();
  const signerAddress = await signer.getAddress();

  const Token = await ethers.getContractFactory("StrataToken");
  const token = Token.attach(record.strataToken);

  const owner: string = await (token as any).owner();
  if (owner.toLowerCase() === signerAddress.toLowerCase()) {
    console.log(`Minting ${amountInTokens} STRT to ${target}...`);
    const tx = await (token as any).mint(target, amount);
    console.log("   tx:", tx.hash);
    await tx.wait();
    console.log("   done.");
  } else {
    console.log(
      `Signer is not the owner. Calling public faucet() — tokens will be sent to ${signerAddress} (NOT ${target}).`,
    );
    const tx = await (token as any).faucet();
    console.log("   tx:", tx.hash);
    await tx.wait();
    console.log("   done. Forward the tokens manually if needed.");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
