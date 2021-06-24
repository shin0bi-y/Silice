// SL 2020-06-12 @sylefeb
//
// Fun with RISC-V!
// RV32I cpu, see README.md
//
//      GNU AFFERO GENERAL PUBLIC LICENSE
//        Version 3, 19 November 2007
//      
//  A copy of the license full text is included in 
//  the distribution, please refer to it for details.

// Clocks
$$if ICESTICK then
import('../common/icestick_clk_60.v')
$$end
$$if FOMU then
import('../common/fomu_clk_20.v')
$$end

$$config['bram_wmask_byte_wenable_width'] = 'data'

// pre-compilation script, embeds compiled code within a string
$$dofile('pre_include_asm.lua')

$$addrW = 12

// include the processor
$include('ice-v.ice')

// --------------------------------------------------
// SOC
// --------------------------------------------------

algorithm main( // I guess this is the SOC :-D
  output uint5 leds,
$$if OLED then
  output uint1 oled_clk,
  output uint1 oled_mosi,
  output uint1 oled_dc,
  output uint1 oled_resn,
  output uint1 oled_csn(0),
$$end
$$if not SIMULATION then    
  ) <@cpu_clock> {
  // clock  
$$if ICESTICK then
  icestick_clk_60 clk_gen (
    clock_in  <: clock,
    clock_out :> cpu_clock
  ); 
$$elseif FOMU then
  uint1 cpu_clock  = uninitialized;
  fomu_clk_20 clk_gen (
    clock_in  <: clock,
    clock_out :> cpu_clock
  );   
$$end
$$else
) {
$$end

$$if OLED then
  uint1 displ_en = uninitialized;
  uint1 displ_dta_or_cmd <: mem.wdata[10,1];
  uint8 displ_byte       <: mem.wdata[0,8];
  oled display(
    enable          <: displ_en,
    data_or_command <: displ_dta_or_cmd,
    byte            <: displ_byte,
    oled_din        :> oled_mosi,
    oled_clk        :> oled_clk,
    oled_dc         :> oled_dc,
  );
$$end

  // ram
  // - uses template "bram_wmask_byte", that turns wenable into a byte mask
  bram uint32 mem<"bram_wmask_byte">[1536] = $meminit$;

  // cpu
  rv32i_cpu cpu( mem <:> mem );

  // io mapping
  always {
$$if OLED then
    displ_en = 0;
$$end
    if (mem.wenable[0,1] & cpu.wide_addr[11,1]) {
      leds      = mem.wdata[0,5] & {5{cpu.wide_addr[0,1]}};
$$if SIMULATION then
      if (mem.wdata[0,5]) { __display("LEDs: %b",leds); }
$$end      
$$if OLED then
      // command
      displ_en  = (mem.wdata[9,1] | mem.wdata[10,1]) & cpu.wide_addr[1,1];
      // reset
      oled_resn = !(mem.wdata[0,1] & cpu.wide_addr[2,1]);
$$end
    }
  }

  // run the CPU
  () <- cpu <- ();

}

// --------------------------------------------------
// Sends bytes to the OLED screen
// produces a quarter freq clock with one bit traveling a four bit ring
// data is sent one main clock cycle before the OLED clock raises

$$if OLED then

algorithm oled(
  input   uint1 enable,   input   uint1 data_or_command, input  uint8 byte,
  output  uint1 oled_clk, output  uint1 oled_din,        output uint1 oled_dc,
) <autorun> {

  uint2 osc        = 1;
  uint1 dc         = 0;
  uint8 sending    = 0;
  uint8 busy       = 0;
  
  always {
    oled_dc  =  dc;
    osc      =  busy[0,1] ? {osc[0,1],osc[1,1]} : 2b1;
    oled_clk =  busy[0,1] && (osc[0,1]); // SPI Mode 0
    if (enable) {
      dc         = data_or_command;
      oled_dc    = dc;
      sending    = {byte[0,1],byte[1,1],byte[2,1],byte[3,1],
                    byte[4,1],byte[5,1],byte[6,1],byte[7,1]};
      busy       = 8b11111111;
    } else {
      oled_din   = sending[0,1];
      sending    = osc[0,1] ? {1b0,sending[1,7]} : sending;
      busy       = osc[0,1] ? busy>>1 : busy;
    }
  }
}

$$end

// --------------------------------------------------
