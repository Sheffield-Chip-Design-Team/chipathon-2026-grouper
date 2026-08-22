/*
 *  Linker script for the GrouperSoC bootloader (sw/boot/bootloader.c)
 *
 *  Imported from new/bootloader/soc.ld and retargeted at this repo's memory
 *  map. The bootloader runs from ROM out of reset, receives an image over the
 *  UART into RAM, and then swaps the banks. Built by
 *  sw/scripts/build_bootloader.sh.
 *
 *  It is deliberately not the same script as sw/boot/soc.ld: the bootloader
 *  has no ResetHandler (sw/boot/start_rv32e.S jumps straight to main), so
 *  there is nothing to copy .data down to RAM. Anything that would land in
 *  .data or .bss is therefore an error, and the ASSERTs at the bottom catch
 *  it rather than letting the image read uninitialised RAM at run time.
 */


/*
 *  Declare the memory units supported in this system.
 *
 *  bank_switch resets to 0, so ROM answers at zero and RAM at 0x4000_0000 -
 *  see the decode on mem_la_addr[31:29] in hw/rtl/cpu_ss.sv and ROM_BASE /
 *  RAM_BASE in sw/src/config.h. Both are aliased across their whole 512 MiB
 *  slice; these are the intended aliases.
 *
 *  Lengths are what cpu_ss's ROM_ADDR_WIDTH=8 / RAM_ADDR_WIDTH=10 address
 *  (hw/rtl/digital_ss.sv). rom_ss implements fewer words than the ROM window
 *  holds, so build_bootloader.sh checks the image against rom_ss's MEM_WORDS
 *  as well - that is the limit that actually bites.
 */

MEMORY
{
   ROM   (rx)  : ORIGIN = 0x00000000, LENGTH = 1K
   RAM   (rwx) : ORIGIN = 0x40000000, LENGTH = 4K
}


SECTIONS
{

   /*
    * The '.text' section contains code and read-only data
    * we would like this to go into ROM
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

   } > ROM = 0


   /*
    * Initialised data. Kept only so that a stray .data object shows up as a
    * section rather than a link error with no explanation; the ASSERT below
    * is what actually rejects it.
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

   } > RAM   AT > ROM


   /*
    * Uninitialised data. Same story as .data - nothing zeroes it, so the
    * ASSERT below keeps it empty.
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


   /*
    * The following line assigns a symbol for the "bottom" of
    * the the stack. This symbol is used by the startup code in
    * order to initialise the stack pointer.
    *
    * The stack lives at the top of RAM, growing down towards the image the
    * bootloader is writing at the bottom of RAM. sw/boot/bootloader.c is
    * written to keep its usage tiny for that reason.
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
 * Nothing in the bootloader initialises RAM, so nothing may depend on RAM
 * having been initialised. Fail the link rather than the silicon.
 */
ASSERT(_edata == _sdata, "bootloader has a .data section, but nothing copies it to RAM - make the object const or a compile-time constant")
ASSERT(_ebss == _sbss, "bootloader has a .bss section, but nothing zeroes it - make the object a local")

/*
 * The ENTRY section can be used to tell an emulator where
 * to start executing the code
 */
ENTRY(reset_vec)
