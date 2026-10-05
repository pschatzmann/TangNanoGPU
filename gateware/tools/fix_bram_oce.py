#!/usr/bin/env python3
"""Post-synthesis netlist fix for yosys 0.33's Gowin block-RAM mapping.

yosys 0.33 (what Linux distributions still ship) maps inferred memories
with the BSRAM output clock enable (OCE) tied low; upstream ties it high
since January 2024. On a real GW2AR-18 a block with OCE low never updates
its output register, so every read returns garbage - found on hardware by
the arduino-tangnano20k core (see its docs/ARCHITECTURE.md). The same fix
is applied here: drive OCE from the read port's clock enable. Newer yosys
versions already do the right thing and this script then changes nothing.

Usage: fix_bram_oce.py netlist.json
"""
import json
import sys

# cell type -> [(oce port, read clock-enable port)]
OCE_PORTS = {
    "SP": [("OCE", "CE")], "SPX9": [("OCE", "CE")],
    "SDP": [("OCE", "CEB")], "SDPX9": [("OCE", "CEB")],
    "SDPB": [("OCE", "CEB")], "SDPX9B": [("OCE", "CEB")],
    "DP": [("OCEA", "CEA"), ("OCEB", "CEB")], "DPX9": [("OCEA", "CEA"), ("OCEB", "CEB")],
    "DPB": [("OCEA", "CEA"), ("OCEB", "CEB")], "DPX9B": [("OCEA", "CEA"), ("OCEB", "CEB")],
    "pROM": [("OCE", "CE")], "pROMX9": [("OCE", "CE")],
}


def main(path):
    with open(path) as f:
        netlist = json.load(f)
    changed = 0
    for module in netlist["modules"].values():
        for cell in module.get("cells", {}).values():
            conns = cell["connections"]
            for oce, ce in OCE_PORTS.get(cell["type"], []):
                if oce in conns and ce in conns and conns[oce] != conns[ce]:
                    conns[oce] = list(conns[ce])
                    changed += 1
    if changed:
        with open(path, "w") as f:
            json.dump(netlist, f)
    print(f"fix_bram_oce: {changed} block RAM port(s) patched")


if __name__ == "__main__":
    main(sys.argv[1])
