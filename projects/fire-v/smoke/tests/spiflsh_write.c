volatile unsigned char* const LEDS     = (unsigned char*)0x90000000;
volatile unsigned int*  const SPIFLASH = (unsigned int* )0x90000008;

long time() 
{
  int cycles;
  asm volatile ("rdcycle %0" : "=r"(cycles));
  return cycles;
}

void pause(int cycles)
{ 
  long tm_start = time();
  while (time() - tm_start < cycles) { }
}

#include "../mylibc/spiflash.c"

void main()
{
  spiflash_init();


//  unsigned char buf[256];
//  spiflash_copy(0x0/*from begining*/,buf,256);
  
//  unsigned char i = 0;
//  *LEDS = 0;  
//  while (1) { 
//    *LEDS = buf[i];
//    i = i + 1;
//    pause(2500000); // 0.25 sec
//  }

  spiflash_busy_wait();
  spiflash_erase4KB(0x100000 /*1MB offset*/);
  
  spiflash_busy_wait();
  spiflash_write_begin(0x100000);
  for (int i = 0; i < 256 ; i++) {
    spiflash_write_next(255-i);
  }
  spiflash_write_end();
  
}
