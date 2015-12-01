import CacheTypes::*;
import Vector::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import MemUtil::*;
import StQ::*;
import Ehr::*;


typedef enum{Ready, StartMiss, SendFillReq, WaitFillResp} CacheStatus 
    deriving(Eq, Bits);
module mkDCache(WideMem mem, DCache ifc);
    // Track the cache state
    Reg#(CacheStatus) status <- mkReg(Ready);

    // The cache memory
    Vector#(CacheRows, Reg#(CacheLine)) dataArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(Maybe#(CacheTag))) 
            tagArray <- replicateM(mkReg(Invalid));
    Vector#(CacheRows, Reg#(Bool)) dirtyArray <- replicateM(mkReg(False));

    // Book keeping
    Fifo#(2, Data) hitQ <- mkBypassFifo;
    Reg#(MemReq) missReq <- mkRegU;
    Fifo#(2, MemReq) memReqQ <- mkCFFifo;
    Fifo#(2, CacheLine) memRespQ <- mkCFFifo;


    function CacheWordSelect getWord(Addr addr) = truncate(addr >> 2);
    function CacheIndex getIndex(Addr addr) = truncate(addr >> 6);
    function CacheTag getTag(Addr addr) = truncateLSB(addr);

    rule startMiss (status == StartMiss);

        // calculate cache index and tag
        $display("[[Cache]] Start Miss");
        CacheWordSelect sel = getWord(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = tagArray[idx];

        // figure out if a writeback is necessary
        let dirty = dirtyArray[idx];
        if (isValid(tag) && dirty) begin
            $display("[[Cache]] -- Writeback dirty cache line --");
            let addr = {fromMaybe(?, tag), idx, sel, 2'b0}; // TODO look here
            memReqQ.enq(MemReq {op: St, addr: addr, data:?});
        end
        
        status <= SendFillReq;

    endrule


    rule sendFillReq (status == SendFillReq);

        $display("[[Cache]] Send Fill Request");
        memReqQ.enq(MemReq {op: Ld, addr: missReq.addr, data:?});
        status <= WaitFillResp;

    endrule


    rule waitFillResp (status == WaitFillResp);
        
        // calculate cache index and tag
        $display("[[Cache]] Wait Fill Response");
        CacheWordSelect sel = getWord(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = getTag(missReq.addr);
        
        // set cache line with data
        let line = memRespQ.first;
        tagArray[idx] <= Valid(tag);
        
        /// check load
        if (missReq.op == Ld) begin
            // enqueue result into hit queue
            dirtyArray[idx] <= False;
            hitQ.enq(line[sel]);
        end
        else begin
            // store
            line[sel] = missReq.data;
            dirtyArray[idx] <= True;
        end
        dataArray[idx] <= line;
        
        // dequeue response queue
        memRespQ.deq;

        // reset status
        status <= Ready;
    endrule


    rule sendToMemory;

        // dequeue to get DRAM request
        $display("[[Cache]] Sending to DRAM");
        memReqQ.deq;
        let r = memReqQ.first;

        // translate data to cache line
        CacheIndex idx = getIndex(r.addr);
        CacheLine line = dataArray[idx];
        
        // create enable signal
        Bit#(CacheLineWords) en;
        if (r.op == St) en = '1;
        else en = '0; 

        mem.req(WideMemReq{
            write_en: en,
            addr: r.addr,
            data: line
        } );

    endrule


    rule getFromMemory;

        // get DRAM response
        $display("[[Cache]] Getting from DRAM");
        let line <- mem.resp();
        memRespQ.enq(line);
    
    endrule


    method Action req(MemReq r) if (status == Ready);
    
        // calculate cache index and tag
        $display("[Cache] Processing request");
        CacheWordSelect sel = getWord(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        // check if in cache
        let hit = False;
        if (tagArray[idx] matches tagged Valid .currTag 
            &&& currTag == tag) hit = True;

        // check load
        if (r.op == Ld) begin
            if (hit) begin
                $display("[Cache] Load hit");
                hitQ.enq(dataArray[idx][sel]);
            end
            else begin
                $display("[Cache] Load miss");
                missReq <= r;
                status <= StartMiss;
            end
        end
        else begin // store request
            if (hit) begin
                $display("[Cache] Write hit");
                dataArray[idx][sel] <= r.data;
                dirtyArray[idx] <= True;
            end
            else begin
                $display("[Cache] Write miss");
                missReq <= r;
                status <= StartMiss;
            end
        end
    endmethod


    method ActionValue#(Data) resp;
        $display("[Cache] Processing response");
        hitQ.deq;
        return hitQ.first;
    endmethod



endmodule


/*
module mkDCacheStQ(WideMem mem, DCache ifc);
	// TODO: blocking cache with store queue for Ex 2
endmodule


module mkDCacheLHUSM(WideMem mem, DCache ifc);
	// TODO: cache wht store queue and allows load hit under store miss for Ex 3
endmodule
*/
