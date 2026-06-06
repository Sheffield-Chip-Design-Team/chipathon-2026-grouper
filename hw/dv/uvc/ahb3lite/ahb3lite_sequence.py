from pyuvm import uvm_sequence, ConfigDB

class AHB3LiteBaseSequence(uvm_sequence):
    def __init__(self, name="ahb3_base_sequence"):
        super().__init__(name)
        self.seqr = None

    def get_config(self):
        self.seqr = ConfigDB().get(None, "", "AHB3LITE_SEQR")

    async def send_items(self, items):
        for item in items:
            await self.start_item(item)
            await self.finish_item(item)
