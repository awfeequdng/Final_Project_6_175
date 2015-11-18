import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Fifo::*;
import Ehr::*;
import Btb::*;
import Scoreboard::*;
import Bht::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;
import ICache::*;
import DCache::*;
import CacheTypes::*;
import WideMemInit::*;
import MemUtil::*;
import Vector::*;
import FShow::*;


// TODO: implement this processor


(* synthesize *)
module mkProc(Proc);
    Ehr#(2, Addr)  pcReg <- mkEhr(?);
    CsrFile         csrf <- mkCsrFile;




	// main memory
    Fifo#(2, DDR3_Req)  ddr3ReqFifo  <- mkCFFifo;
    Fifo#(2, DDR3_Resp) ddr3RespFifo <- mkCFFifo;
    WideMemInitIfc       ddr3InitIfc <- mkWideMemInitDDR3( ddr3ReqFifo );
    Bool memReady = ddr3InitIfc.done;

	// wrap DDR3 to widemem
    WideMem           wideMemWrapper <- mkWideMemFromDDR3( ddr3ReqFifo, ddr3RespFifo );
	// split widemem to 2: XXX: only take action after reset
	// otherwise the guard may fail, and we get garbage resp
    Vector#(2, WideMem)     wideMems <- mkSplitWideMem( memReady && csrf.started, wideMemWrapper );

	// I cache
	ICache iCache <- mkICache(wideMems[1]);

	// D cache
`ifdef LHUSM
    DCache dCache <- mkDCacheLHUSM(wideMems[0]);
`elsif STQ
    DCache dCache <- mkDCacheStQ(wideMems[0]);
`else
    DCache dCache <- mkDCache(wideMems[0]);
`endif

	// some garbage may get into ddr3RespFifo during soft reset
    rule drainMemResponses( !csrf.started );
        ddr3RespFifo.deq;
    endrule




    method ActionValue#(CpuToHostData) cpuToHost if(csrf.started);
        let ret <- csrf.cpuToHost;
        return ret;
    endmethod

    method Action hostToCpu(Bit#(32) startpc) if ( !csrf.started && memReady && !ddr3RespFifo.notEmpty );
        csrf.start(0); // only 1 core, id = 0
        pcReg[0] <= startpc;
    endmethod

    interface WideMemInitIfc memInit = ddr3InitIfc;
    interface DDR3_Client ddr3client = toGPClient( ddr3ReqFifo, ddr3RespFifo );
endmodule

