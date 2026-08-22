/*=========================================================================*/
/*  C Run-Time for bare metal system-on-chip                               */
/*=========================================================================*/

#include <stdint.h>

/*=========================================================================*/
/*  DEFINE: All extern Data                                                */
/*=========================================================================*/
/* these are defined by the linker script */
extern uint32_t _sbss;
extern uint32_t _ebss;
extern uint32_t _sdata;
extern uint32_t _edata;
extern uint32_t _etext;

/* This is the main */
extern int main (void);

/***************************************************************************/
/*  ResetHandler                                                           */
/*                                                                         */
/*  This is called before main and never returns                           */
/***************************************************************************/
// The stack usage can be decreased to 0, by marking the function as "naked",
// this means the function doesn't do any register preservation, etc. (or any other compiler prologue/epilogue code)
// This may break things, so should only really be used on non-returning functions

__attribute__ ((naked))
void ResetHandler (void)
{
   uint32_t *pDest;
   uint32_t *pSrc;
   
   /* Initialised data must be copied from ROM to RAM before calling main */
   pSrc = &_etext;
   pDest = &_sdata;

   if ( pSrc != pDest ) {
     /* this will only be run if there is any read-only memory */
     while(pDest < &_edata)
     {
        *pDest++ = *pSrc++;
     }
   }

   /* BSS segment (if it exists) must be cleared before calling main */
   pDest = &_sbss;
   while(pDest < &_ebss)
   {
      *pDest++ = 0;
   }
   
   
   /* call main */       
   main();    
   
   /* This is an embedded program so won't terminate even if main returns */
   while(1) {};    

}
