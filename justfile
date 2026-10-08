# STRATA — top-level task runner
#
# Install just: brew install just
#
# Common commands:
#   just up                # print Iteration 3 local stack instructions
#   just down              # tear it down
#   just deploy-hardhat    # deploy + write deployments/ + abi/
#   just deploy-amoy       # deploy to Polygon Amoy
#   just sync-abi          # contracts/abi → lib/assets/abi
#   just print-deploy-env  # show dart-defines + host .env lines
#   just host-run          # Iteration 2 off-chain host
#   just host-run-chain    # Iteration 3 (needs addresses in env)
#   just flutter-run-chain # Flutter with injected contract addresses
#   just test-all          # host + hardhat + flutter tests
#   just reconcile         # POST /admin/reconcile
#   just ap-check          # validate Pi AP templates

set positional-arguments

# ---------- contracts ----------
deploy-localhost:
    cd contracts && npx hardhat compile && npx hardhat run scripts/deploy.ts --network localhost

deploy-amoy:
    cd contracts && npx hardhat compile && npx hardhat run scripts/deploy.ts --network amoy

# Deploy to in-process Hardhat (no separate node) — good for CI / ABI generation.
deploy-hardhat:
    cd contracts && npx hardhat compile && npx hardhat run scripts/deploy.ts --network hardhat

# ---------- host_node ----------
host-run:
    cd host_node && \
      DEMO_MODE=true \
      CHAIN_ENABLED=false \
      STRATA_NFT_FAKE=true \
      STRATA_WG_FAKE=true \
      MDNS_ENABLED=true \
      ADMIN_TOKEN=local-dev-token \
      uvicorn strata_host.main:app --host 0.0.0.0 --port 8080 --reload

# Requires SESSION_ESCROW_ADDRESS + STRATA_TOKEN_ADDRESS + HOST_* in the environment
# (or host_node/.env). Use `just print-deploy-env` after deploy.
host-run-chain:
    cd host_node && \
      DEMO_MODE=true \
      CHAIN_ENABLED=true \
      STRATA_NFT_FAKE=true \
      STRATA_WG_FAKE=true \
      MDNS_ENABLED=true \
      ADMIN_TOKEN=local-dev-token \
      uvicorn strata_host.main:app --host 0.0.0.0 --port 8080 --reload

host-test:
    cd host_node && PYTHONPATH=src pytest -q -m "not integration and not e2e"

# ---------- Raspberry Pi AP (Iteration 1) ----------
ap-check:
    bash host_node/ap/scripts/check_ap.sh

ap-render:
    bash host_node/ap/scripts/render_config.sh

ap-setup:
    sudo bash host_node/ap/scripts/setup_ap.sh

ap-teardown:
    sudo bash host_node/ap/scripts/teardown_ap.sh

ap-verify:
    sudo bash host_node/ap/scripts/verify_ap.sh

iter2-verify:
    sudo bash host_node/scripts/verify_iter2_pi.sh

# ---------- flutter ----------
sync-abi:
    dart run scripts/sync_abi.dart

# Print dart-defines + host env from the latest deployments/*.json
print-deploy-env network="hardhat":
    #!/usr/bin/env bash
    set -euo pipefail
    f="contracts/deployments/{{network}}.json"
    if [[ ! -f "$f" ]]; then
      echo "missing $f — run: just deploy-{{network}}" >&2
      exit 1
    fi
    token=$(python3 -c "import json;print(json.load(open('$f'))['strataToken'])")
    escrow=$(python3 -c "import json;print(json.load(open('$f'))['sessionEscrow'])")
    chain=$(python3 -c "import json;print(json.load(open('$f'))['chainId'])")
    echo "STRATA_TOKEN=$token"
    echo "SESSION_ESCROW=$escrow"
    echo "CHAIN_ID=$chain"
    echo ""
    echo "# Flutter:"
    echo "flutter run --dart-define=STRATA_TOKEN=$token --dart-define=SESSION_ESCROW=$escrow --dart-define=CHAIN_ID=$chain"
    echo ""
    echo "# host_node/.env:"
    echo "CHAIN_ENABLED=true"
    echo "STRATA_TOKEN_ADDRESS=$token"
    echo "SESSION_ESCROW_ADDRESS=$escrow"
    echo "CHAIN_ID=$chain"

flutter-run: sync-abi
    flutter run -d chrome --web-port 9000

flutter-run-chain network="hardhat":
    #!/usr/bin/env bash
    set -euo pipefail
    just sync-abi
    f="contracts/deployments/{{network}}.json"
    token=$(python3 -c "import json;print(json.load(open('$f'))['strataToken'])")
    escrow=$(python3 -c "import json;print(json.load(open('$f'))['sessionEscrow'])")
    chain=$(python3 -c "import json;print(json.load(open('$f'))['chainId'])")
    rpc="http://127.0.0.1:8545"
    if [[ "{{network}}" == "amoy" ]]; then
      rpc="https://rpc-amoy.polygon.technology"
    fi
    # STRATA_ADMIN_TOKEN is optional — enables live nftables MAC list in My Hosting.
    # Must match host_node ADMIN_TOKEN (local demo uses local-dev-token).
    flutter run \
      --dart-define=STRATA_TOKEN="$token" \
      --dart-define=SESSION_ESCROW="$escrow" \
      --dart-define=CHAIN_ID="$chain" \
      --dart-define=RPC_URL="$rpc" \
      --dart-define=HOST_API_URL=http://127.0.0.1:8080 \
      --dart-define=STRATA_ADMIN_TOKEN=local-dev-token

flutter-test:
    flutter test

# ---------- e2e / reconcile ----------
e2e:
    cd host_node && pytest -m e2e tests/e2e

reconcile base_url="http://127.0.0.1:8080" token="local-dev-token":
    curl -sf -X POST "{{base_url}}/admin/reconcile" \
      -H "Authorization: Bearer {{token}}"

# ---------- ops helpers ----------
nft-show:
    sudo nft list set inet strata strata_authed || echo "(no rules loaded — fake mode?)"

test-all:
    just host-test
    cd contracts && node ./node_modules/hardhat/internal/cli/bootstrap.js test
    flutter test

# Local Iteration 3 blockchain demo (no Pi). Requires Hardhat node in another terminal:
#   cd contracts && npx hardhat node
iter3-local-demo:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="$HOME/.local/node/bin:$PATH"
    cd contracts && npx hardhat compile
    cd ..
    PYTHONPATH=host_node/src python3 host_node/scripts/iter3_local_chain_e2e.py

# Periodic checkpoints + router-driven closeSession against a local chain
# (no Pi). Requires `cd contracts && npx hardhat node` in another terminal.
iter3-settlement-demo:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="$HOME/.local/node/bin:$PATH"
    cd contracts && npx hardhat compile
    cd ..
    STRATA_NFT_FAKE=true STRATA_WG_FAKE=true python3 host_node/scripts/iter3_host_settlement_e2e.py

# ---------- compose-style up/down ----------
up:
    @echo "Starting Iteration 3 stack — open terminals:"
    @echo "  1) cd contracts && npx hardhat node"
    @echo "  2) just deploy-localhost && just sync-abi && just print-deploy-env localhost"
    @echo "  3) export addresses into host_node/.env then: just host-run-chain"
    @echo "  4) just flutter-run-chain network=localhost"
    @echo "See docs/DEMO_TOPOLOGY.md"

down:
    @pkill -f 'uvicorn strata_host.main' 2>/dev/null || true
    @pkill -f 'hardhat node' 2>/dev/null || true
    @echo "stopped host_node + hardhat (if they were running)"
