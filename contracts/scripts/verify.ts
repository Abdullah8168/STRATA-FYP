import { run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "hardhat";

async function main() {
  if (!process.env.POLYGONSCAN_API_KEY) {
    console.error(
      "POLYGONSCAN_API_KEY is not set. Get a free key from https://amoyscan.com (or polygonscan.com → API).",
    );
    process.exit(1);
  }

  const filename = network.name === "amoy" ? "amoy.json" : `${network.name}.json`;
  const recordPath = path.join(__dirname, "..", "deployments", filename);
  if (!fs.existsSync(recordPath)) {
    console.error(`No deployment record found at ${recordPath}.`);
    console.error(`Run \`npx hardhat run scripts/deploy.ts --network ${network.name}\` first.`);
    process.exit(1);
  }

  const record = JSON.parse(fs.readFileSync(recordPath, "utf-8"));
  console.log(`Verifying contracts from ${path.basename(recordPath)} on ${network.name}...`);

  const initialSupply = ethers.parseEther("10000000");

  await safeVerify("StrataToken", record.strataToken, [initialSupply, record.deployer]);
  await safeVerify("SessionEscrow", record.sessionEscrow, [record.strataToken, record.deployer]);

  console.log("\nDone.");
}

async function safeVerify(name: string, address: string, constructorArgs: unknown[]) {
  console.log(`→ ${name} @ ${address}`);
  try {
    await run("verify:verify", { address, constructorArguments: constructorArgs });
    console.log("   verified.");
  } catch (err: any) {
    if (typeof err.message === "string" && err.message.toLowerCase().includes("already verified")) {
      console.log("   already verified — skipping.");
      return;
    }
    throw err;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
