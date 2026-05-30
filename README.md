#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
# Grouper SoC — Quick Start

## 1) Create + activate a virtual environment
```bash
python3 -m venv .env
source .env/bin/activate
```

## 2) Install FuseSoC and dependencies
```bash
pip install --upgrade pip
pip install fusesoc
```

## 3) Add FuseSoC libraries (local + picorv32)
```bash
fusesoc library add grouper_soc .
fusesoc library add --sync-type git --sync-uri https://github.com/YosysHQ/picorv32 picorv32
fusesoc library update picorv32
```

## 4) Run simulation (no export)
```bash
fusesoc run --no-export --target=tb_top grouper_soc
```

## Notes
- The simulation uses the SystemVerilog testbench top `picorv32_hello_tb`.
- Verilator is required in PATH.
EOF
