import CacheTypes::*;
import Types::*;
import Fifo::*;
import Vector::*;
import MemTypes::*;
import MemInit::*;
import MemUtil::*;
import SimMem::*;
import WideMemInit::*;

module mkTranslator(WideMem mem, Cache ifc);
    
    Fifo#(16, CacheWordSelect) idxQ <- mkCFFifo;

    method Action req(MemReq r);

        // translate data to cache line
        Vector#(CacheLineWords, Data) line = replicate(0);
        CacheWordSelect idx = truncate(r.addr >> 2);
        line[idx] = r.data;
        
        // create enable signal
        Bit#(CacheLineWords) en = 0;
        if (r.op == Ld) begin
            idxQ.enq(idx);
        end
        else begin
            en[idx] = 1;
        end

        mem.req(WideMemReq{
            write_en: en,
            addr: r.addr,
            data: line
        } );
    endmethod

    method ActionValue#(MemResp) resp;
        let line <- mem.resp();
        let tag = idxQ.first;
        idxQ.deq;
        return line[tag];
    endmethod

endmodule

