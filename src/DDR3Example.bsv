import GetPut::*;
import ClientServer::*;
import Memory::*;
import CacheTypes::*;
import WideMemInit::*;
import MemUtil::*;
import Vector::*;

// other packages and type definitions

(* synthesize *)
module mkProc(Proc);
    Ehr#(2, Addr)  pcReg <- mkEhr(?);
    CsrFile         csrf <- mkCsrFile;

	// other processor stats and components

	// interface FIFOs to real DDR3
    Fifo#(2, DDR3_Req)  ddr3ReqFifo  <- mkCFFifo;
    Fifo#(2, DDR3_Resp) ddr3RespFifo <- mkCFFifo;
	// module to initialize DDR3
    WideMemInitIfc       ddr3InitIfc <- mkWideMemInitDDR3( ddr3ReqFifo );
    Bool memReady = ddr3InitIfc.done;

	// wrap DDR3 to WideMem interface
    WideMem           wideMemWrapper <- mkWideMemFromDDR3( ddr3ReqFifo, ddr3RespFifo );
	// split WideMem interface to two (use it in a multiplexed way) 
	// This spliter only take action after reset (i.e. memReady && csrf.started)
	// otherwise the guard may fail, and we get garbage DDR3 resp
    Vector#(2, WideMem)     wideMems <- mkSplitWideMem( memReady && csrf.started, wideMemWrapper );
	// Instruction cache should use wideMems[1]
	// Data cache should use wideMems[0]

	// some garbage may get into ddr3RespFifo during soft reset
	// this rule drains all such garbage
    rule drainMemResponses( !csrf.started );
        ddr3RespFifo.deq;
    endrule

	// other rules

    method ActionValue#(CpuToHostData) cpuToHost if(csrf.started);
        let ret <- csrf.cpuToHost;
        return ret;
    endmethod

	// add ddr3RespFifo empty into guard, make sure that garbage has been drained
    method Action hostToCpu(Bit#(32) startpc) if ( !csrf.started && memReady && !ddr3RespFifo.notEmpty );
        csrf.start(0); // only 1 core, id = 0
        pcReg[0] <= startpc;
    endmethod

	// interface for testbench to initialize DDR3
    interface WideMemInitIfc memInit = ddr3InitIfc;
	// interface to real DDR3 controller
    interface DDR3_Client ddr3client = toGPClient( ddr3ReqFifo, ddr3RespFifo );
endmodule

