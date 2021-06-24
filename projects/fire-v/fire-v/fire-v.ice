// SL 2020-12-02 @sylefeb
// ------------------------- 
// The Fire-V core - RV32I CPU
// ------------------------- 
// 
// Note: rdinstret and rdcycle are limited to 32 bits
//       rdtime reports user_data instead of time
//
// --------------------------------------------------
//
//      GNU AFFERO GENERAL PUBLIC LICENSE
//        Version 3, 19 November 2007
//      
//  A copy of the license full text is included in 
//  the distribution, please refer to it for details.

$include('risc-v.ice')

$$if FIREV_MULDIV then
$$div_width  = 32
$$div_signed = 1
$include('../../common/divint_std.ice')
$$end

// --------------------------------------------------
// The Risc-V RV32I CPU

algorithm rv32i_cpu(
  input uint26   boot_at,
  input uint32   user_data,
  rv32i_ram_user ram,
  output uint26  predicted_addr,    // next predicted address
  output uint1   predicted_correct, // was the prediction correct?
) <autorun> {
  
  // does not have to be simple_dualport_bram, but results in a smaller design
  simple_dualport_bram int32 xregsA[32] = {0,pad(uninitialized)};
  simple_dualport_bram int32 xregsB[32] = {0,pad(uninitialized)};
  
  uint1  instr_ready(0);
$$if SIMULATION then  
  uint1  halt(0);
$$end
  uint5  write_rd    = uninitialized;
  uint1  jump        = uninitialized;  
  uint1  branch      = uninitialized;

  uint3  csr         = uninitialized;
  uint3  aluOp       = uninitialized;  
  uint1  sub         = uninitialized;
  uint1  signedShift = uninitialized;
$$if FIREV_MULDIV then
  uint1  muldiv      = uninitialized;
$$end
  uint1  dry_resume(0);
  
  uint32 instr(0);
  uint26 pc(0);
  uint32 next_instr(0);
  uint26 next_pc(0);

  uint26 next_pc_p4 <:: next_pc + 4;
  uint26 next_pc_p8 <:: next_pc + 8;

  uint1 pcOrReg     = uninitialized;
  uint1 regOrImm    = uninitialized;
  
  uint1 load_store  = uninitialized;
  uint1 store       = uninitialized;
  uint3 loadStoreOp = uninitialized;
  uint1 rd_enable   = uninitialized;
  
  uint1 saved_store       = uninitialized;
  uint3 saved_loadStoreOp = uninitialized;
  uint1 saved_rd_enable   = uninitialized;
  
  uint32 refetch_addr = uninitialized;
  uint1  refetch_rw(0);
  
  int32 aluA        = uninitialized;
  int32 aluB        = uninitialized;
  int32 imm         = uninitialized;
  int32 regA        = uninitialized;
  int32 regB        = uninitialized;
  
  decode dec(
    instr       <: instr,
    pc          <: pc,
    regA        <: regA,
    regB        <: regB,
    write_rd    :> write_rd,
    jump        :> jump,
    branch      :> branch,
    load_store  :> load_store,
    store       :> store,
    loadStoreOp :> loadStoreOp,
    aluOp       :> aluOp,
    sub         :> sub,
$$if FIREV_MULDIV then
    muldiv      :> muldiv,
$$end    
    signedShift :> signedShift,
    pcOrReg     :> pcOrReg,
    regOrImm    :> regOrImm,
    csr         :> csr,
    rd_enable   :> rd_enable,
    aluA        :> aluA,
    aluB        :> aluB,
    imm         :> imm,
  );
 
  uint3  funct3 <:: Btype(instr).funct3; 
  uint1  branch_or_jump = uninitialized;

  int32  alu_out     = uninitialized;
  int32  wreg        = uninitialized;
  intops alu(
    pc          <:: pc,
    xa          <: aluA,
    xb          <: aluB,
    imm         <: imm,
    pcOrReg     <: pcOrReg,
    regOrImm    <: regOrImm,
    aluOp       <: aluOp,
    sub         <: sub,    
    signedShift <: signedShift,
$$if FIREV_MULDIV then
    muldiv      <: muldiv,
$$end    
    csr         <: csr,
    cycle      <:: cycle,
$$if not FIREV_NO_INSTRET then    
    instret    <:: instret,
$$end    
    user_data  <:  user_data,
    r           :> alu_out,
    ra         <:: regA,
    rb         <:: regB,
    funct3     <:  funct3,
    branch     <:  branch,
    jump       <:  jump,
    j          :>  branch_or_jump,
    w          :>  wreg,
  );

  uint32 cycle(0);
$$if not FIREV_NO_INSTRET then     
  uint32 instret(0);
$$end

$$if SIMULATION then
  uint32 cycle_last_retired(0);
$$end

  uint1  refetch         = 1;
  uint1  wait_next_instr = 0;
  uint1  commit_decode   = 0;
  uint1  do_load_store   = 0;
  uint1  start           = 1;

  uint4  state   = uninitialized;

  // maintain ram in_valid low (pulses high when needed)
  ram.in_valid    := 0; 
  
  always {
$$if FIREV_MULDIV then
    uint1 alu_wait <:: alu.aluPleaseWait;
$$else
    uint1 alu_wait <:: 0; // never wait ALU in RV32I
$$end  

    state = {
                    refetch                         & (ram.done | start),
                   ~refetch         & do_load_store &  ram.done,  // performing load store, data available
                    (wait_next_instr)               & (ram.done | dry_resume),  // instruction avalable
                    commit_decode   & ~alu_wait
                  };
$$if SIMULATION then
    if (halt) {
      state = 0;
    }
$$end                  

$$if verbose then
    if (ram.done) {
      __display("**** ram done (cycle %d) **** ram.data_out @%h = %h",cycle,ram.addr,ram.data_out);        
    }
$$end

$$state_REFETCH    = 8
$$state_LOAD_STORE = 4
$$state_ALU_FETCH  = 2
$$state_COMMIT     = 1

    switch (state) {

      case $state_REFETCH$: {
$$if verbose then
      if (~reset) {
        __display("----------- STATE 8: refetch ------------- (cycle %d)",cycle);
      }
$$end
        refetch         = 0;

        // record next instruction
        next_instr      = ram.data_out;
        // prepare load registers for next instruction
        xregsA.addr0    = Rtype(next_instr).rs1;
        xregsB.addr0    = Rtype(next_instr).rs2;
        predicted_correct = instr_ready;
        predicted_addr    = next_pc_p4;

        // refetch
        ram.addr          = start ? boot_at : refetch_addr;
        // cold start?
        next_pc           = start ? boot_at : next_pc;
        if (start & ~reset) {
          __display("CPU RESET %d (@%h) start:%b",state,next_pc,start);
        }        
        start             = reset;
        ram.rw            = refetch_rw;
        ram.in_valid      = ~reset;
        instr_ready       = do_load_store;
        wait_next_instr   = ~do_load_store;

      }
    
      case $state_LOAD_STORE$: {
$$if verbose then
        __display("----------- STATE 4: load / store ------------- (cycle %d)",cycle);
$$end        
        do_load_store   = 0;
        // data with memory access
        if (~saved_store) { 
          // finalize load
          uint32 tmp = uninitialized;
          switch ( saved_loadStoreOp[0,2] ) {
            case 2b00: { // LB / LBU
              tmp = { {24{(~saved_loadStoreOp[2,1])&ram.data_out[ 7,1]}},ram.data_out[ 0,8]};
            }
            case 2b01: { // LH / LHU
              tmp = { {16{(~saved_loadStoreOp[2,1])&ram.data_out[15,1]}},ram.data_out[ 0,16]};
            }
            case 2b10: { // LW
              tmp = ram.data_out;  
            }
            default: { tmp = 0; }
          }            
          // write result to register
          xregsA.wenable1 = saved_rd_enable;
          xregsB.wenable1 = saved_rd_enable;
          xregsA.wdata1   = tmp;
          xregsB.wdata1   = tmp;
        }
        
        // be optimistic: request next-next instruction
        ram.addr       = next_pc_p4;
        // register conflict?
        if ((Rtype(next_instr).rs1 == xregsA.addr1
          || Rtype(next_instr).rs2 == xregsB.addr1
          || Rtype(instr     ).rs1 == xregsA.addr1
          || Rtype(instr     ).rs2 == xregsB.addr1) & saved_rd_enable) {
          // too bad, but we have to write a register that was already
          // read for the prefetched instructions ... play again!
          refetch         = 1;
          refetch_addr    = pc;
          next_pc         = pc;
          instr_ready     = 0;
$$if verbose then
          __display("****** register conflict *******");
$$end          
        } else {
          commit_decode     = 1;
        }
        ram.in_valid      = 1;
        ram.rw            = 0;
        predicted_addr    = next_pc_p8;
        predicted_correct = 1;
      } // case 4

      case $state_ALU_FETCH$: {
$$if verbose then      
      __display("----------- STATE 2 : ALU / fetch ------------- (cycle %d)",cycle);
$$end      
        // Note: ALU for previous (if any) is running ...
        wait_next_instr   = 0;
        // record next instruction
        next_instr        = ram.data_out;
        // prepare load registers for next instruction
        xregsA.addr0      = Rtype(next_instr).rs1;
        xregsB.addr0      = Rtype(next_instr).rs2;
        commit_decode     = 1;
        predicted_correct = 1;
        // be optimistic: request next-next instruction
        ram.addr          = next_pc_p4;
        ram.in_valid      = 1;
        ram.rw            = 0;
      }
      
      case $state_COMMIT$: {
$$if verbose then     
        __display("----------- STATE 1 : commit / decode ------------- (cycle %d) [alu_wait %b]",cycle,alu_wait);
        if (~instr_ready) {
          __display("========> [next instruction] load_store %b branch_or_jump %b",load_store,branch_or_jump);
        } else {
           __display("========> [ALU done <<%h>> (%d since)] pc %h alu_out %h load_store:%b store:%b branch_or_jump:%b rd_enable:%b write_rd:%d aluA:%d aluB:%d regA:%d regB:%d",instr,cycle-cycle_last_retired,pc,alu_out,load_store,store,branch_or_jump,rd_enable,write_rd,aluA,aluB,regA,regB);
          cycle_last_retired = cycle;
        }
$$end        
        commit_decode = 0;
        // Note: nothing received from memory
$$if SIMULATION then
        halt   = instr_ready & (instr == 0);
        if (halt) { __display("HALT on zero-instruction"); }
$$end
        // commit previous instruction
        // load store next?
        do_load_store     = instr_ready & load_store;
        saved_store       = store;
        saved_loadStoreOp = loadStoreOp;
        saved_rd_enable   = rd_enable;
        // need to refetch from RAM next?
        refetch           = instr_ready & (branch_or_jump | load_store); // ask to fetch from the new address (cannot do it now, memory is busy with prefetch)        
        refetch_addr      = alu_out;
        refetch_rw        = load_store & store;

$$if FIREV_MULDIV then
        dry_resume        = (muldiv & aluOp[2,1]);
$$end        

$$if verbose then
if (refetch) {
  __display("  [refetch from] %h",refetch_addr);
}
if (dry_resume) {
  __display("  [dry_resume from] %h",next_pc);
}
$$end
        // attempt to predict read ...
        predicted_addr    = refetch ? alu_out[0,26] : next_pc_p8;
        predicted_correct = 1;
        
        // wait for next instr?
        wait_next_instr = (~refetch & ~do_load_store) | ~instr_ready;

        // prepare a potential store     // Note: it is ok to manipulate ram.data_in as only reads can concurrently occur
        // TODO: simplify (see ice-v)
        switch (loadStoreOp) {
          case 3b000: { // SB
              switch (alu_out[0,2]) {
                case 2b00: { ram.data_in[ 0,8] = regB[ 0,8]; ram.wmask = 4b0001; }
                case 2b01: { ram.data_in[ 8,8] = regB[ 0,8]; ram.wmask = 4b0010; }
                case 2b10: { ram.data_in[16,8] = regB[ 0,8]; ram.wmask = 4b0100; }
                case 2b11: { ram.data_in[24,8] = regB[ 0,8]; ram.wmask = 4b1000; }
              }
          }
          case 3b001: { // SH
              switch (alu_out[1,1]) {
                case 1b0: { ram.data_in[ 0,16] = regB[ 0,16]; ram.wmask = 4b0011; }
                case 1b1: { ram.data_in[16,16] = regB[ 0,16]; ram.wmask = 4b1100; }
              }
          }
          case 3b010: { // SW
            ram.data_in = regB; ram.wmask = 4b1111;
          }
          default: { ram.data_in = 0; }
        }

        // write result to register
        xregsA.wdata1   = branch_or_jump ? next_pc : alu_out;
        xregsB.wdata1   = branch_or_jump ? next_pc : alu_out;
        xregsA.addr1    = write_rd;
        xregsB.addr1    = write_rd;
        xregsA.wenable1 = instr_ready & (~refetch | jump) & rd_enable;
        xregsB.wenable1 = instr_ready & (~refetch | jump) & rd_enable;

        // setup decoder and ALU for instruction i+1
        // => decoder starts immediately, ALU on next cycle
        instr   = next_instr;
        pc      = next_pc;
        next_pc = (branch_or_jump & instr_ready) ? refetch_addr : next_pc_p4;
        regA    = ((xregsA.addr0 == xregsA.addr1) & xregsA.wenable1) ? xregsA.wdata1 : xregsA.rdata0;
        regB    = ((xregsB.addr0 == xregsB.addr1) & xregsB.wenable1) ? xregsB.wdata1 : xregsB.rdata0;   
$$if not FIREV_NO_INSTRET then    
       if (instr_ready) {
         instret = instret + 1;
       }
$$end       
       instr_ready       = 1;
      }
    } // switch
        
    cycle           = cycle + 1;

  } // while
}

// --------------------------------------------------
// decode next instruction

algorithm decode(
  input  uint32  instr,
  input  uint26  pc,
  input  int32   regA,
  input  int32   regB,
  output uint5   write_rd,
  output uint1   jump,
  output uint1   branch,
  output uint1   load_store,
  output uint1   store,
  output uint3   loadStoreOp,
  output uint3   aluOp,
  output uint1   sub,  
  output uint1   signedShift,
$$if FIREV_MULDIV then
  output uint1   muldiv,
$$end  
  output uint1   pcOrReg,
  output uint1   regOrImm,
  output uint3   csr,
  output uint1   rd_enable,
  output int32   aluA,
  output int32   aluB,
  output int32   imm,
) <autorun> {

  int32 imm_u  <:: {Utype(instr).imm31_12,12b0};
  int32 imm_j  <:: {
           {12{Jtype(instr).imm20}},
           Jtype(instr).imm_19_12,
           Jtype(instr).imm11,
           Jtype(instr).imm10_1,
           1b0};
  int32 imm_i  <:: {{20{instr[31,1]}},Itype(instr).imm};
  int32 imm_b  <::  {
            {20{Btype(instr).imm12}},
            Btype(instr).imm11,
            Btype(instr).imm10_5,
            Btype(instr).imm4_1,
            1b0
            };
  int32 imm_s  <:: {{20{instr[31,1]}},Stype(instr).imm11_5,Stype(instr).imm4_0};
  
  uint5 opcode <:: instr[ 2, 5];
  
  uint1 AUIPC  <:: opcode == 5b00101;
  uint1 LUI    <:: opcode == 5b01101;
  uint1 JAL    <:: opcode == 5b11011;
  uint1 JALR   <:: opcode == 5b11001;
  uint1 Branch <:: opcode == 5b11000;
  uint1 Load   <:: opcode == 5b00000;
  uint1 Store  <:: opcode == 5b01000;
  uint1 IntImm <:: opcode == 5b00100;
  uint1 IntReg <:: opcode == 5b01100;
  uint1 CSR    <:: opcode == 5b11100;

  uint1 no_rd  <:: (Branch | Store);

  jump         := (JAL | JALR);
  branch       := (Branch);
  store        := (Store);
  load_store   := (Load | Store);
  regOrImm     := (IntReg);
  aluOp        := (IntImm | IntReg) ? {Itype(instr).funct3} : 3b000;
  sub          := (IntReg & Rtype(instr).sub);
$$if FIREV_MULDIV then
  muldiv       := (IntReg & Rtype(instr).muldiv);
$$end  
  signedShift  := IntImm & instr[30,1]; /*SRLI/SRAI*/

  loadStoreOp  := Itype(instr).funct3;

  csr          := {CSR,instr[20,2]}; // we grab only the bits for 
               // low bits of rdcycle (0xc00), rdtime (0xc01), instret (0xc02)

  write_rd     := Rtype(instr).rd;
  rd_enable    := (write_rd != 0) & ~no_rd;  
  
  pcOrReg      := (AUIPC | JAL | Branch);

$$if FIREV_MUX_A_DECODER then
  aluA         := (LUI) ? 0 : ((AUIPC | JAL | Branch) ? __signed({6b0,pc[0,26]}) : regA);
$$else
  aluA         := (LUI) ? 0 : regA;
$$end
  
$$if not FIREV_MUX_B_DECODER then    
  aluB         := regB;
$$end

  always {

    switch (opcode)
     {
      case 5b00101: { // AUIPC
        imm         = imm_u;
       }
      case 5b01101: { // LUI
        imm         = imm_u;
       }
      case 5b11011: { // JAL
        imm         = imm_j;
       }
      case 5b11000: { // branch
        imm         = imm_b;
       }
      case 5b11001: { // JALR
        imm         = imm_i;
       }
      case 5b00000: { // load
        imm         = imm_i;
       }
      case 5b00100: { // integer, immediate
        imm         = imm_i;
       }
      case 5b01000: { // store
        imm         = imm_s;
       }
       default: {
         imm        = {32{1bx}};
       }
     }

$$if FIREV_MUX_B_DECODER then    
     aluB = regOrImm ? (regB) : imm;
$$end

  }
}

// --------------------------------------------------
// Performs integer computations

algorithm intops(
  input   uint26 pc,
  input   int32  xa,
  input   int32  xb,
  input   int32  imm,
  input   uint3  aluOp,
  input   uint1  sub,
$$if FIREV_MULDIV then
  input   uint1  muldiv,
  output  uint1  aluPleaseWait(0),
$$end
  input   uint1  pcOrReg,
  input   uint1  regOrImm,
  input   uint1  signedShift,
  input   uint3  csr,
  input   uint32 cycle,
$$if not FIREV_NO_INSTRET then      
  input   uint32 instret,
$$end  
  input   uint32 user_data,
  output  int32  r,
  input   int32  ra,
  input   int32  rb,
  input   uint3  funct3,
  input   uint1  branch,
  input   uint1  jump,
  output  uint1  j,
  output  int32  w,
) {
  
  // 3 cases
  // reg +/- reg (intops)
  // reg +/- imm (intops)
  // pc  + imm   (else)
  
$$if FIREV_MUX_A_DECODER then      
  int32 a <: xa;
$$else
  int32 a <: pcOrReg  ? __signed({6b0,pc[0,26]}) : xa;
$$end
  
$$if FIREV_MUX_B_DECODER then      
  int32 b <: xb;
$$else
  int32 b <: regOrImm ? (xb) : imm;
$$end

$$if FIREV_MULDIV then
  int32 div_n(0);
  int32 div_d(0);
  div32 div(
    inum <:: div_n,
    iden <:: div_d,
  );
  uint1 dividing(0);
$$end

  always { // this part of the algorithm is executed every clock  
    switch ({aluOp}) {
      case 3b000: { // ADD / SUB
$$if FIREV_MERGE_ADD_SUB then      
        r = a + (sub ? -b : b); // smaller, slower...
$$else        
        r = sub ? (a - b) : (a + b);
$$end        
      }     
      case 3b010: { // SLTI
        if (__signed(xa)   < __signed(b)) { r = 32b1; } else { r = 32b0; }
      }
      case 3b011: { // SLTU
        if (__unsigned(xa) < __unsigned(b)) { r = 32b1; } else { r = 32b0; }
      }
      case 3b100: { r = xa ^ b;} // XOR
      case 3b110: { r = xa | b;} // OR
      case 3b111: { r = xa & b;} // AND
      case 3b001: { r = (xa <<< b[0,5]); } // SLLI
      case 3b101: { r = signedShift ? (xa >>> b[0,5]) : (xa >> b[0,5]); } // SRLI / SRAI
      default:    { r = {32{1bx}}; }
    }

    if (csr[2,1]) {
      switch (csr[0,2]) {
        case 2b00: { r = cycle;     }
        case 2b01: { r = user_data; }
$$if not FIREV_NO_INSTRET then    
        case 2b10: { r = instret;   }
$$end      
        default:   { r = {32{1bx}}; }
      }
    }

$$if FIREV_MULDIV then
    div_n    = a;
    div_d    = b;
    dividing = dividing & muldiv & aluOp[2,1];
    if (muldiv) {
      switch ({aluOp}) {
        case 3b000: { // MUL
          //__display("MULTIPLICATION %d * %d",a,b);
          r        = a * b;
        }
        case 3b100: { // DIV
          if (~aluPleaseWait && ~dividing) {
            //__display("trigger");
            aluPleaseWait = 1;
            div <- ();
          } else {
            //if (isdone(div)) {
              //__display("DIVISION %d / %d = %d",a,b,div.ret);
            //}
            aluPleaseWait = ~ isdone(div);
          }
          r        = div.ret;
          dividing = 1;
        }
        default:   { r = {32{1bx}}; }
      }
    } 
$$end

    switch (funct3) {
      case 3b000: { j = jump | (branch & (ra == rb)); } // BEQ
      case 3b001: { j = jump | (branch & (ra != rb)); } // BNE
      case 3b100: { j = jump | (branch & (__signed(ra)   <  __signed(rb)));   } // BLT
      case 3b110: { j = jump | (branch & (__unsigned(ra) <  __unsigned(rb))); } // BLTU
      case 3b101: { j = jump | (branch & (__signed(ra)   >= __signed(rb)));   } // BGE
      case 3b111: { j = jump | (branch & (__unsigned(ra) >= __unsigned(rb))); } // BGEU
      default:    { j = jump; }
    }

  }
}

// --------------------------------------------------
