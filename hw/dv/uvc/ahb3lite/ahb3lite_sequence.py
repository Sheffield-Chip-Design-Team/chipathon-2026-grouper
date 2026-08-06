from pyuvm import uvm_sequence, ConfigDB

class AHB3LiteBaseSequence(uvm_sequence):
    def get_config(self):
        self.sequencer = ConfigDB().get(None, "", "AHB3LITE_SEQR")

    async def send_items(self, items):
        for item in items:
            await self.start_item(item)
            await self.finish_item(item)
