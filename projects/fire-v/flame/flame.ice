// SL 2020-12-02 @sylefeb
// ------------------------- 
// Flame: a hardware rasterizer for Fire-V
// ------------------------- 
//      GNU AFFERO GENERAL PUBLIC LICENSE
//        Version 3, 19 November 2007
//      
//  A copy of the license full text is included in 
//  the distribution, please refer to it for details.
// ------------------------- 
/*

 - parameter: FLAME_BLAZE=1 if on Blaze, nil otherwise (Wildfire)

*/

group vertex
{
  int16 x = uninitialized, int16 y = uninitialized, int16 z = uninitialized
}

group transform 
{
  int8 m00 = 127, int8 m01 = 0,   int8 m02 = 0,
  int8 m10 = 0,   int8 m11 = 127, int8 m12 = 0,
  int8 m20 = 0,   int8 m21 = 0,   int8 m22 = 127,
  int16 tx = 0,   int16 ty = 0,
}

algorithm edge_walk(
  input  uint10  y,
  input  uint10 x0,
  input  uint10 y0,
  input  uint10 x1,
  input  uint10 y1,
  input  int24  interp,
  input  uint2  prepare,
  output uint10 xi,
  output uint1  intersects
) <autorun> {
$$if SIMULATION then
  uint16 cycle = 0;
  uint16 cycle_last = 0;
$$end

  uint1  in_edge  <:: ((y0 <= y && y1 >= y) || (y1 <= y && y0 >= y)) && (y0 != y1);
  int10  last_y     = uninitialized;
  int20  xi_full    = uninitialized;

  intersects := in_edge;

 always {
$$if SIMULATION then
    cycle = cycle + 1;
$$end
 
    if (prepare[1,1]) {
      last_y  = __signed(y0) - 1;
      xi_full = x0 << 10;
  $$if SIMULATION then
//      __display("prepared! (x0=%d y0=%d last_y=%d xi=%d interp=%d)",x0,y0,last_y,xi>>10,interp);
  $$end
    } else {
      if (__signed(y) == last_y + __signed(1)) {
        xi      = (y == y1) ? x1 : (xi_full >> 10);
        xi_full = (xi_full + interp);
        last_y  = y;
  $$if SIMULATION then
  // __display("  next [%d cycles] : y:%d interp:%d xi:%d it:%b)",cycle-cycle_last,y,interp,xi_full>>10,intersects);
  $$end
      }
    }
  }
}

// ------------------------- 

algorithm ram_writer_wildfire( 
  sdram_user     sd,
  input  uint1   fbuffer,
  input  uint1   start,
  input  uint1   end,
  input  uint1   next,
  input  uint8   color,
  input  uint10  x,
  input  uint10  y,
  output uint1   done
) <autorun> {

  uint19 addr <:: {x[3,7],3b000} + (y << 10);

  always {
    sd.rw = 1;
    sd.data_in[{x[0,3],3b000},8] = color;
    if (start | x[0,3]==3b000) {
      sd.wmask = start ? 8b00000000 : 8b00000001;
    } else {
      sd.wmask[x[0,3],1] = next ? 1 : sd.wmask[x[0,3],1];
    }
    sd.in_valid      = end     || (next && ((x[0,3])==7));
    done             = sd.done || (next && ((x[0,3])!=7));
    sd.addr          = end ? sd.addr : {1b0,~fbuffer,5b0,addr};
  }
}

// ------------------------- 

algorithm ram_writer_blaze( 
  sdram_user     sd,
  input  uint1   fbuffer,
  input  uint1   start,
  input  uint1   end,
  input  uint1   next,
  input  uint4   color,
  input  uint10  x,
  input  uint10  y,
  output uint1   done
) <autorun> {

  //  320 x 200, 4bpp    x>>2 + y*80
  uint14 addr <:: x[3,7] + (y << 5) + (y << 3) + (~fbuffer ? 0 : 8000);

  always {
    sd.rw = 1;
    sd.data_in[{x[0,3],2b00},4] = color;
    if (start | x[0,3]==3b000) {
      sd.wmask = start ? 8b00000000 : 8b0000001;
    } else {
      sd.wmask[x[0,3],1] = next ? 1 : sd.wmask[x[0,3],1];
    }
    sd.in_valid      = end     || (next && ((x[0,3])==3b111));
    done             = sd.done || (next && ((x[0,3])!=3b111));
    sd.addr          = end ? sd.addr : addr;
  }
}

// ------------------------- 

algorithm flame_rasterizer(
  sdram_user    sd,
  input  uint1  fbuffer,
  input  vertex v0, // uses 10 bits precision
  input  vertex v1, // uses 10 bits precision
  input  vertex v2, // uses 10 bits precision
  input  int24  ei0,
  input  int24  ei1,
  input  int24  ei2,
  input  uint10 ystart,
  input  uint10 ystop,
  input  uint8  color,
  input  uint1  triangle_in,
  output uint1  drawing=0,
) <autorun> {

$$if SIMULATION then
   uint24 cycle = 0;
$$end
  
  uint10  xi0 = uninitialized;
  uint10  xi1 = uninitialized;
  uint10  xi2 = uninitialized;
  uint1   it0 = uninitialized;
  uint1   it1 = uninitialized;
  uint1   it2 = uninitialized;
  uint10  y   = uninitialized;

  uint1   in_span = uninitialized;
  int11   span_x(-1);
  uint10  stop_x = uninitialized;
  uint2   prepare(0);
  uint1   wait_done(0);
  uint1   sent(0);

  edge_walk e0(
    x0 <: v0.x, y0 <: v0.y,
    x1 <: v1.x, y1 <: v1.y,
    interp  <:  ei0,
    prepare <:: prepare,
    y       <:: y,
    intersects :> it0,
    xi         :> xi0,
    <:auto:>);

  edge_walk e1(
    x0 <: v1.x, y0 <: v1.y,
    x1 <: v2.x, y1 <: v2.y,
    interp  <:  ei1,
    prepare <:: prepare,
    y       <:: y,
    intersects :> it1,
    xi         :> xi1,
    <:auto:>);

  edge_walk e2(
    x0 <: v0.x, y0 <: v0.y,
    x1 <: v2.x, y1 <: v2.y,
    interp  <:  ei2,
    prepare <:: prepare,
    y       <:: y,
    intersects :> it2,
    xi         :> xi2,
    <:auto:>);

  uint1   start    = uninitialized;
  uint1   end      = uninitialized;
  uint1   next     = uninitialized;
  uint1   done     = uninitialized;
$$if not FLAME_BLAZE then
  ram_writer_wildfire writer(
    sd      <:> sd,
    fbuffer <:  fbuffer,
    start   <:: start,
    end     <:: end,
    next    <:: next,
    color   <:  color,
    x       <:: span_x,
    y       <:: y,
    done    :> done
  );
$$else
  ram_writer_blaze writer(
    sd      <:> sd,
    fbuffer <:  fbuffer,
    start   <:: start,
    end     <:: end,
    next    <:: next,
    color   <:  color,
    x       <:: span_x,
    y       <:: y,
    done    :> done
  );
$$end

  uint10  y_p1  <:: y+1;

  start                := 0;
  end                  := 0;
  next                 := 0;

  always {

    if (drawing & ~wait_done) {      
      if (span_x[10,1]) {
        // find the span bounds, start drawing
        uint10 first  = uninitialized;
        uint10 second = uninitialized;
        uint1  nop    = 0;
        // __display("xi0:%d xi1:%d xi2:%d it0:%b it1:%b it2:%b",xi0,xi1,xi2,it0,it1,it2);
        switch (~{it2,it1,it0}) {
          case 3b001: { first = xi1; second = xi2; }
          case 3b010: { first = xi0; second = xi2; }
          case 3b100: { first = xi0; second = xi1; }
          case 3b000: { 
            if (xi0 == xi1) {
              first = xi0; second = xi2; 
            } else {
              first = xi0; second = xi1; 
            }
          }
          default:    { nop = 1; }
        }
        if (first < second) {
          span_x = ~nop ? first : span_x;
          stop_x = second;
        } else {
          span_x = ~nop ? second : span_x;
          stop_x = first;
        }
        start    = ~nop;
        // __display("start span, x %d to %d (y %d)",span_x,stop_x,y);
      } else {
        // write current to sdram
        if (~sent) {
          sent        = 1;
          next        = 1;
        } else {
          if (done) {
            sent = 0;
            if (span_x == stop_x) {
              //__display("stop_x span, x %d y %d",span_x,y);
              drawing   = (y_p1 == ystop) ? 0 : 1;
              y         = y_p1;
              span_x    = -1;
              end       = 1;
              wait_done = 1; // wait last write to be done (edge_writer also needs 1 cycle)
            } else {
              span_x = span_x + 1;
            }
          }
        }
      }
      //if (drawing == 0) {
      //  __display("[cycle %d] done",cycle);
      //}
    } else { // draw_triangle

      if (prepare[0,1]) {
        prepare = {1b0,prepare[1,1]};
        drawing = ~prepare[0,1];
      }
      wait_done = wait_done & ~sd.done;

    }

    if (triangle_in) {
      // __display("[cycle %d] incoming triangle",cycle);
      prepare = 2b11;
      drawing = 0;
      y       = ystart;
    }
$$if SIMULATION then
    cycle = cycle + 1;
$$end    

  }

}

// ------------------------- 

algorithm flame_transform(
  input  transform t,
  input  vertex    v, // uses 10.6 bits precision
  output vertex    tv // uses 10.6 bits precision
) {

  uint3 step(3b1);
  int8  a=uninitialized; int8  b=uninitialized; int8  c=uninitialized; int16  d=uninitialized;
  int24 r=uninitialized;

  always {
    r = ((a*v.x + b*v.y + c*v.z) >>> $7$) + d; // NOTE: this could be using the DSP slices ...
    switch (step) {
      case 3b001: { a = t.m00; b = t.m01; c = t.m02; d =  t.tx; tv.z = r; }
      case 3b010: { a = t.m10; b = t.m11; c = t.m12; d =  t.ty; tv.x = r; }
      case 3b100: { a = t.m20; b = t.m21; c = t.m22; d = 32767; tv.y = r; }
      default: {}
    }
    step = {step[0,2],step[2,1]};
    // __display("trsf %d * %d + %d * %d + %d * %d",a,v.x,b,v.y,c,v.z);
  }

}

// ------------------------- 
