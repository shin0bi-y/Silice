// -------------------------

// VGA driver
$include('../common/vga.ice')

$$if MOJO then
// Clock
import('../common/mojo_clk_100_25.v')
$$end

$$if ICESTICK then
// Clock
import('../common/icestick_clk_25.v')
$$end

$$if ICEBREAKER then
// Clock
import('../common/icebreaker_clk_25.v')
$$end

$$if DE10NANO then
// Clock
import('../common/de10nano_clk_100_25.v')
$$end

$$if ULX3S then
// Clock
import('../common/ulx3s_clk_100_25.v')
$$end

$$if ECPIX5 then
// Clock
import('../common/ecpix5_clk_100_25.v')
$$end

$$if HARDWARE then
// Reset
$include('../common/clean_reset.ice')
$$end

// -------------------------

$$if SIMULATION then
algorithm pll(
  output  uint1 video_clock,
  output  uint1 video_reset,
) <autorun>
{
  uint3 counter = 0;
  uint8 trigger = 8b11111111;
  
  video_clock   := counter[1,1]; // x4 slower (25 MHz)
  video_reset   := (trigger > 0);
  
  always {	  
    counter = counter + 1;
	  trigger = trigger >> 1;
  }
}
$$end

// -------------------------

algorithm frame_display(
  input   uint10 pix_x,
  input   uint10 pix_y,
  input   uint1  pix_active,
  input   uint1  pix_vblank,
  output! uint$color_depth$ pix_red,
  output! uint$color_depth$ pix_green,
  output! uint$color_depth$ pix_blue
) <autorun> {
  // by default r,g,b are set to zero
  pix_red   := 0;
  pix_green := 0;
  pix_blue  := 0; 
  // ---------- show time!
  while (1) {
	  // display frame
	  while (pix_vblank == 0) {
      if (pix_active) {
        pix_blue  = pix_x[4,$color_depth$];
        pix_green = pix_y[4,$color_depth$];
        pix_red   = pix_x[1,$color_depth$];
      }      
    }    
    while (pix_vblank == 1) {} // wait for sync
  }
}

// -------------------------

algorithm main(
  output! uint$NUM_LEDS$ leds,
$$if SIMULATION then
  output  uint1 video_clock,
$$end
$$if VGA then  
  // VGA
  output! uint$color_depth$ video_r,
  output! uint$color_depth$ video_g,
  output! uint$color_depth$ video_b,
  output  uint1 video_hs,
  output  uint1 video_vs
$$end
) 
$$if not ULX3S then
<@video_clock,!video_reset> 
$$end
{
  uint1 video_reset = 0;
  
$$if HARDWARE then
  uint1 video_clock = 0;
$$if MOJO then
  uint1 sdram_clock = 0;
  // --- clock
  clk_100_25 clk_gen (
    CLK_IN1  <: clock,
    CLK_OUT1 :> sdram_clock,
    CLK_OUT2 :> video_clock
  );
$$elseif ICESTICK then
  // --- clock
  uint1 pll_lock = 0;
  icestick_clk_25 clk_gen(
    clock_in  <: clock,
    clock_out :> video_clock,
    lock      :> pll_lock
  );
$$elseif ICEBREAKER then
  // --- clock
  icebreaker_clk_25 clk_gen (
    clock_in  <: clock,
    clock_out :> video_clock
  );
$$elseif DE10NANO then
  // --- clock
  uint1 sdram_clock = 0;
  uint1 pll_lock = 0;
  de10nano_clk_100_25 clk_gen(
    refclk    <: clock,
    outclk_0  :> sdram_clock,
    outclk_1  :> video_clock,
    locked    :> pll_lock,
    rst       <: reset
  ); 
$$elseif ULX3S then
  // --- clock
  uint1 sdram_clock = 0;
  uint1 pll_lock = 0;
  ulx3s_clk_100_25 clk_gen(
    clkin    <: clock,
    clkout0  :> sdram_clock,
    clkout1  :> video_clock,
    locked   :> pll_lock
  ); 
$$elseif ECPIX5 then
  // --- clock
  uint1 sdram_clock = 0;
  uint1 pll_lock = 0;
  ecpix5_clk_100_25 clk_gen(
    clkin    <: clock,
    clkout0  :> sdram_clock,
    clkout1  :> video_clock,
    locked   :> pll_lock
  ); 
$$end
  // --- video reset
  clean_reset vga_rstcond<@video_clock,!reset> (
    out :> video_reset
  );
$$else
  // --- simulation pll
  pll clockgen<@clock,!reset>(
    video_clock   :> video_clock,
    video_reset   :> video_reset,
  );  
$$end

  uint1  active = 0;
  uint1  vblank = 0;
  uint10 pix_x  = 0;
  uint10 pix_y  = 0;

  vga vga_driver (
    vga_hs :> video_hs,
	  vga_vs :> video_vs,
	  active :> active,
	  vblank :> vblank,
	  vga_x  :> pix_x,
	  vga_y  :> pix_y
  );

  frame_display display (
	  pix_x      <: pix_x,
	  pix_y      <: pix_y,
	  pix_active <: active,
	  pix_vblank <: vblank,
	  pix_red    :> video_r,
	  pix_green  :> video_g,
	  pix_blue   :> video_b
  );

  uint8 frame  = 0;

$$if MOJO then
  // unused pins
  spi_miso := 1bz;
  avr_rx := 1bz;
  spi_channel := 4bzzzz;
$$end

$$if SIMULATION then
  // we count a number of frames and stop
  while (frame < 8) {
$$else
  // forever
  while (1) {
$$end
  
    while (vblank == 1) { }
	  $display("vblank off");
    while (vblank == 0) { }
    $display("vblank on");
    frame = frame + 1;

  }
}
