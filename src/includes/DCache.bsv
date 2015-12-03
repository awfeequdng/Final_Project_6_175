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
    Fifo#(1, MemReq) reqQ <- mkBypassFifo;
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
            let addr = {fromMaybe(?, tag), idx, sel, 2'b0};
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


    rule doReq (status == Ready);

        // get request from queue
        MemReq r = reqQ.first;
        reqQ.deq;

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
    endrule


    method Action req(MemReq r);
        reqQ.enq(r);
    endmethod


    method ActionValue#(Data) resp;
        $display("[Cache] Processing response");
        hitQ.deq;
        return hitQ.first;
    endmethod



endmodule


module mkDCacheStQ(WideMem mem, DCache ifc);

    // Track the cache state
    Reg#(CacheStatus) status <- mkReg(Ready);

    // The cache memory
    Vector#(CacheRows, Reg#(CacheLine)) dataArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(Maybe#(CacheTag))) 
            tagArray <- replicateM(mkReg(Invalid));
    Vector#(CacheRows, Reg#(Bool)) dirtyArray <- replicateM(mkReg(False));

    // Book keeping
    Fifo#(2, Data) hitQ <- mkBypassFifo;
    Fifo#(1, MemReq) reqQ <- mkBypassFifo;
    Reg#(MemReq) missReq <- mkRegU;
    Fifo#(2, MemReq) memReqQ <- mkCFFifo;
    Fifo#(2, CacheLine) memRespQ <- mkCFFifo;

    // store queue
    StQ#(StQSize) stq <-mkStQ;

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
            let addr = {fromMaybe(?, tag), idx, sel, 2'b0};
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
            stq.deq;
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


    rule doLoad (status == Ready && reqQ.first.op == Ld);

        // get request from queue
        MemReq r = reqQ.first;
        reqQ.deq;

        // calculate cache index and tag
        $display("[Cache] Processing load request");
        CacheWordSelect sel = getWord(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        // search stb
        let x = stq.search(r.addr);
        if (isValid(x)) hitQ.enq(fromMaybe(?, x));
        else begin

            // check if in cache
            if (tagArray[idx] matches tagged Valid .currTag 
                &&& currTag == tag) begin

                $display("[Cache] Load hit");
                hitQ.enq(dataArray[idx][sel]);
            
            end
            else begin
                $display("[Cache] Load miss");
                missReq <= r;
                status <= StartMiss;
            end
        end
    endrule


    rule doStore (reqQ.first.op == St);

        // enqueue store request
        $display("[Cache] Enqueue store request");
        MemReq r = reqQ.first;
        reqQ.deq;
        stq.enq(r);

    endrule


    rule mvStqToCache (status == Ready && (!reqQ.notEmpty || reqQ.first.op != Ld));

        // get request from store queue
        MemReq r <- stq.issue;

        // calculate cache index and tag
        $display("[Cache] Processing store request");
        CacheWordSelect sel = getWord(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        if (tagArray[idx] matches tagged Valid .currTag 
            &&& currTag == tag) begin

            $display("[Cache] Store hit");
            dataArray[idx][sel] <= r.data;
            dirtyArray[idx] <= True;
            stq.deq;

        end
        else begin
            $display("[Cache] Store miss");
            missReq <= r;
            status <= StartMiss;
        end
    endrule


    method Action req(MemReq r);
        reqQ.enq(r);
    endmethod
    
    method ActionValue#(Data) resp;
        $display("[Cache] Processing response");
        hitQ.deq;
        return hitQ.first;
    endmethod



endmodule


module mkDCacheLHUSM(WideMem mem, DCache ifc);
    
    // Track the cache state
    Reg#(CacheStatus) status <- mkReg(Ready);

    // The cache memory
    Vector#(CacheRows, Reg#(CacheLine)) dataArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(Maybe#(CacheTag))) 
            tagArray <- replicateM(mkReg(Invalid));
    Vector#(CacheRows, Reg#(Bool)) dirtyArray <- replicateM(mkReg(False));

    // Book keeping
    Fifo#(2, Data) hitQ <- mkBypassFifo;
    Fifo#(1, MemReq) reqQ <- mkBypassFifo;
    Reg#(MemReq) missReq <- mkRegU;
    Fifo#(2, MemReq) memReqQ <- mkCFFifo;
    Fifo#(2, CacheLine) memRespQ <- mkCFFifo;

    // store queue
    StQ#(StQSize) stq <-mkStQ;

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
            let addr = {fromMaybe(?, tag), idx, sel, 2'b0};
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
            stq.deq;
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


    rule doLoad (reqQ.first.op == Ld);

        // get request from queue
        MemReq r = reqQ.first;
            
        // calculate cache index and tag
        $display("[Cache] Processing load request");
        CacheWordSelect sel = getWord(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        // check if no cache miss is being processed
        if (status == Ready) begin

            // dequeue request
            reqQ.deq;

            // search stb
            let x = stq.search(r.addr);
            if (isValid(x)) hitQ.enq(fromMaybe(?, x));
            else begin

                // check if in cache
                if (tagArray[idx] matches tagged Valid .currTag 
                    &&& currTag == tag) begin

                    $display("[Cache] Load hit");
                    hitQ.enq(dataArray[idx][sel]);
                
                end
                else begin
                    $display("[Cache] Load miss");
                    missReq <= r;
                    status <= StartMiss;
                end
            end
        end
        else begin
            
            // cache miss is begin processed, check if it's a store
            // and that nothing is coming back this cycle
            if (missReq.op == St && !mem.respValid) begin

                // check if load hit
                let x = stq.search(r.addr);
                if (isValid(x)) hitQ.enq(fromMaybe(?, x));
                else if (tagArray[idx] matches tagged Valid .currTag 
                    &&& currTag == tag) begin
                        $display("[Cache] Load hit under store miss");
                        hitQ.enq(dataArray[idx][sel]);
                end
            end
        end
    endrule


    rule doStore (reqQ.first.op == St);

        // enqueue store request
        $display("[Cache] Enqueue store request");
        MemReq r = reqQ.first;
        reqQ.deq;
        stq.enq(r);

    endrule


    rule mvStqToCache (status == Ready && (!reqQ.notEmpty || reqQ.first.op != Ld));

        // get request from store queue
        MemReq r <- stq.issue;

        // calculate cache index and tag
        $display("[Cache] Processing store request");
        CacheWordSelect sel = getWord(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        if (tagArray[idx] matches tagged Valid .currTag 
            &&& currTag == tag) begin

            $display("[Cache] Store hit");
            dataArray[idx][sel] <= r.data;
            dirtyArray[idx] <= True;
            stq.deq;

        end
        else begin
            $display("[Cache] Store miss");
            missReq <= r;
            status <= StartMiss;
        end
    endrule


    method Action req(MemReq r);
        reqQ.enq(r);
    endmethod
    
    method ActionValue#(Data) resp;
        $display("[Cache] Processing response");
        hitQ.deq;
        return hitQ.first;
    endmethod


endmodule
