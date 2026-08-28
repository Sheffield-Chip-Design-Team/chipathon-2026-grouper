from pyuvm import uvm_sequencer


class AHBUartVirtualSequencer(uvm_sequencer):
  # FIXME - make the vseqr smarter so it automatically knows what to do
  # when presented a sequence item?

  def __init__(self, name, parent, ahb_agent=None, uart_agent=None):
    # super() is what gives this component its logger (uvm_report_object),
    # registers it with its parent, and builds seq_item_export/seq_q - skip it
    # and the object is not in the UVM hierarchy at all, so no phase runs on it.
    super().__init__(name, parent)
    self.ahb_agent  = ahb_agent
    self.uart_agent = uart_agent
    self.ahb_seqr   = None
    self.uart_seqr  = None

  def connect_phase(self):
    # Not build_phase: that runs top-down, so the agents' own build_phase -
    # where AHB3LiteAgent/UartAgent create their sequencers - has not run yet
    # when the env builds this component.
    self.ahb_seqr  = self.ahb_agent.sequencer
    self.uart_seqr = self.uart_agent.sequencer
