
# Base class for SHaRC cocotb VIPs

from cocotb import logging
import logging

import cocotb

class VIP_Base():

    def __init__(self):
        # global ID assignment
        global_vip_id       = getattr(VIP_Base, "global_id", 0)
        VIP_Base.global_id  = global_vip_id + 1
        self.id             = global_vip_id
        self.is_active      = True        

        # set up logger
        self.log = logging.getLogger(f"cocotb.tb.vip.{self.id}")
        self.log.setLevel("INFO")  # Optional: set log level per class

    def resolve_handle(self, root, path: str):
        """
        Given a root module and a hierarchical path like 'module.signal',
        return the handle for tb.dut.module.signal
        """
        
        obj = root
        self.log.debug(f"resolving: {path} for root {root}")
        
        if path == "":
            self.log.warning(f"Could not resolve handle for null path")
            return obj
        
        if "." not in path:
            self.log.debug(f"resolving single-level path: {path} for root {root}")
            if hasattr(obj, path):
                self.log.debug(f"resolved single-level path: {path} for root {root}")
                return getattr(obj, path)
            else:   
                self.log.warning(f"Could not resolve handle for single path: {path}")

        for part in path.split("."):
            if hasattr(obj, part):
                obj = getattr(obj, part)
            else:
                self.log.warning(f"Could not resolve handle for path: {part}")
        return obj

