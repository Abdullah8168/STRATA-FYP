import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const INITIAL_SUPPLY = ethers.parseEther("10000000"); // 10M STRT

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  const balance = await ethers.provider.getBalance(deployerAddress);
  const chainId = (await ethers.provider.getNetwork()).chainId;

  console.log("\n=== STRATA Phase E deploy ===");
  console.log("network    :", network.name, `(chainId ${chainId})`);
  console.log("deployer   :", deployerAddress);
  console.log("balance    :", ethers.formatEther(balance), "MATIC\n");

  if (balance === 0n && network.name !== "hardhat") {
    throw new Error(
      `Deployer ${deployerAddress} has no native balance on ${network.name}. ` +
        "Top up at https://faucet.polygon.technology before retrying.",
    );
  }

  console.log("→ Deploying StrataToken...");
  const Token = await ethers.getContractFactory("StrataToken");
  const token = await Token.deploy(INITIAL_SUPPLY, deployerAddress);
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  const tokenTx = token.deploymentTransaction();
  console.log("   StrataToken @", tokenAddress, "(tx", tokenTx?.hash, ")");

  console.log("→ Deploying SessionEscrow...");
  const Escrow = await ethers.getContractFactory("SessionEscrow");
  const escrow = await Escrow.deploy(tokenAddress, deployerAddress);
  await escrow.waitForDeployment();
  const escrowAddress = await escrow.getAddress();
  const escrowTx = escrow.deploymentTransaction();
  console.log("   SessionEscrow @", escrowAddress, "(tx", escrowTx?.hash, ")");

  // Persist the deployment record.
  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const filename =
    network.name === "amoy" ? "amoy.json" : `${network.name}.json`;
  const outPath = path.join(outDir, filename);

  const record = {
    network: network.name,
    chainId: Number(chainId),
    deployedAt: new Date().toISOString(),
    strataToken: tokenAddress,
    sessionEscrow: escrowAddress,
    deployer: deployerAddress,
    txHashes: {
      strataToken: tokenTx?.hash ?? null,
      sessionEscrow: escrowTx?.hash ?? null,
    },
  };
  fs.writeFileSync(outPath, JSON.stringify(record, null, 2));
  console.log("\n   wrote", path.relative(process.cwd(), outPath));

  // Copy ABIs to abi/ for downstream consumers.
  const abiDir = path.join(__dirname, "..", "abi");
  if (!fs.existsSync(abiDir)) fs.mkdirSync(abiDir, { recursive: true });
  for (const name of ["StrataToken", "SessionEscrow"]) {
    const artifact = JSON.parse(
      fs.readFileSync(
        path.join(__dirname, "..", "artifacts", "contracts", `${name}.sol`, `${name}.json`),
        "utf-8",
      ),
    );
    fs.writeFileSync(
      path.join(abiDir, `${name}.json`),
      JSON.stringify({ contractName: name, abi: artifact.abi }, null, 2),
    );
    console.log("   wrote abi/", `${name}.json`);
  }

  console.log("\n=== Next steps ===");
  console.log(
    `1) Sync Flutter ABIs:\n` +
      `     just sync-abi\n` +
      `   Then run Flutter with dart-defines (never hardcode addresses):\n` +
      `     flutter run \\\n` +
      `       --dart-define=STRATA_TOKEN=${tokenAddress} \\\n` +
      `       --dart-define=SESSION_ESCROW=${escrowAddress} \\\n` +
      `       --dart-define=CHAIN_ID=${chainId}`,
  );
  console.log(
    `2) Set host_node/.env:\n` +
      `     CHAIN_ENABLED=true\n` +
      `     STRATA_TOKEN_ADDRESS=${tokenAddress}\n` +
      `     SESSION_ESCROW_ADDRESS=${escrowAddress}\n` +
      `     AMOY_WSS_URL=<wss RPC for this network>\n` +
      `     HOST_WALLET_ADDRESS=<host EOA>\n` +
      `     HOST_SIGNING_PRIVATE_KEY=<same EOA key>\n` +
      `     CHAIN_ID=${chainId}`,
  );
  console.log(
    `3) Verify on explorer (optional):\n` +
      `     POLYGONSCAN_API_KEY=... npx hardhat run scripts/verify.ts --network ${network.name}`,
  );
  console.log(`4) Topology cheat-sheet: docs/DEMO_TOPOLOGY.md`);
  console.log();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
