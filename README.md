# Grouper SoC — Quick Start

## 1) Create + activate a virtual environment
```bash
python3.12 -m venv .env
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
fusesoc library add https://github.com/Sheffield-Chip-Design-Team/picorv32
fusesoc library update picorv32
```

## 4) Run simulation (no export)
```bash
fusesoc run --no-export --target=tb_top grouper_soc
```

## Notes
- The simulation uses the SystemVerilog testbench top `picorv32_hello_tb`.
- This flow requires at least python 3.12 (3.13 is the maximum version for fusesoc + cocotb)
- Verilator 5+ is required in PATH.
