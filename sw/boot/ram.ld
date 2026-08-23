/*
 *  Linker script for a RISC-V based System-on-Chip
 *
 *  This version links a RAM-resident image - the form the bootloader in
 *  sw/boot/bootloader.c receives over the UART. Use sw/boot/soc.ld instead for
 *  a ROM-resident image (build_fw.sh --link rom, the default).
 *
 *  Linking with this script draws a "LOAD segment with RWX permissions"
 *  warning from ld. That is expected and harmless here: there is one region,
 *  it holds code and data both, and there is no MMU to separate them.
 */


/*
 *  Declare the memory units supported in this system.
 *
 *  One region, because after the bank switch there is only one: writing 1 to
 *  BANK_SWITCH_ADDR (0x7ffffffc) swaps RAM to 0x0000_0000 and resets the CPU,
 *  which then fetches its reset vector from RAM. So the image is *linked* for
 *  zero even though the bootloader *writes* it through the 0x4000_0000 alias,
 *  which is where RAM answers while the bootloader itself is still running
 *  from ROM. See the decode in hw/rtl/cpu_ss.sv.
 *
 *  4 KiB is cpu_ss's RAM_ADDR_WIDTH=10 (hw/rtl/digital_ss.sv). Everything -
 *  code, data, bss and the stack - has to fit in it.
 */

MEMORY
{
   RAM   (rwx) : ORIGIN = 0x00000000, LENGTH = 4K
}


SECTIONS
{

   /*
    * Code and read-only data. Unlike the ROM-resident link there is nowhere
    * else for it to live, so it goes into RAM with everything else.
    */
   .text :
   {
      _stext = .;          /* Provide the name for the start of this section */

      CREATE_OBJECT_SYMBOLS

      *(.reset.text)       /* Include the startup assembly code first */

      *(.text)
      *(.text.*)

      . = ALIGN(4);        /* Align the start of the rodata part */
      *(.rodata)
      *(.rodata.*)

      . = ALIGN(4);        /* Align the start of the small rodata part */
      *(.srodata)
      *(.srodata.*)

      . = ALIGN(4);        /* Align the end of the section */
      _etext = .;          /* Provide the name for the end of this section */

   } > RAM = 0


   /*
    * Initialised data. It is already in RAM - the bootloader loaded it there
    * along with the code - so there is nothing to copy. Placing it directly
    * after .text makes _sdata equal _etext, and ResetHandler's
    * "if (pSrc != pDest)" guard then skips the copy loop.
    */
   .data :
   {
      . = ALIGN(4);        /* Align the start of the section */
      _sdata = .;          /* Provide the name for the start of this section */

      *(.data)
      *(.data.*)

      . = ALIGN(4);        /* Align the start of the small data part */
      _small_data = .;     /* Provide the name for the start of this section */
      *(.sdata)
      *(.sdata.*)

      . = ALIGN(4);        /* Align the end of the section */
      _edata = .;          /* Provide the name for the end of this section */

   } > RAM


   /*
    * Uninitialised data. Still cleared by ResetHandler - the bootloader only
    * writes the bytes the image actually carries, so bss arrives as whatever
    * the previous occupant of that RAM left behind.
    */
   .bss :
   {
      . = ALIGN(4);        /* Align the start of the section */
      _sbss = .;           /* Provide the name for the start of this section */

      *(.sbss)
      *(.sbss.*)

      . = ALIGN(4);        /* Align the start of bss part */
      *(.bss)
      *(.bss.*)

      . = ALIGN(4);        /* Align the end of the section */
      _ebss = .;           /* Provide the name for the end of this section */

   } > RAM

   .irq :
   {
      . = ALIGN(4);        /* Align the start of the section */
      _sirq = .;           /* Provide the name for the start of this section */

      *(.irq.regs)

      _eirq = .;           /* Provide the name for the end of this section */
   } > RAM


   /*
    * The following line assigns a symbol for the "bottom" of
    * the the stack. This symbol is used by the startup code in
    * order to initialise the stack pointer
    */
   _estack = ORIGIN(RAM) + LENGTH(RAM);


   /*
    * Assigning the special "__global_pointer$" symbol allows the
    * compiler to use gp relative addresses in the range:
    *  (__global_pointer$ - 0x800) - (__global_pointer$ + 0x7FF)
    *
    * The symbol is used by the startup code in order to initialise
    * the gp register.
    *
    * Here the _small_data symbol is used to indicate the start of the
    * .sdata section
    */
   __global_pointer$ = _small_data + 0x800;


   /*
    * Exception frames are not supported by this embedded system
    * so we will discard the 'eh_frame' section
    */
   /DISCARD/ :
   {
      *(.eh_frame)
   }

}

/*
 * The ENTRY section can be used to tell an emulator where
 * to start executing the code
 */
ENTRY(reset_vec)
