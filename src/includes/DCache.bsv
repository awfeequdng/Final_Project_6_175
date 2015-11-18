import CacheTypes::*;
import Vector::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import MemUtil::*;
import StQ::*;
import Ehr::*;

// TODO: implement differet kinds of caches

module mkDCache(WideMem mem, DCache ifc);
	// TODO: blocking cache for Ex 1
endmodule


module mkDCacheStQ(WideMem mem, DCache ifc);
	// TODO: blocking cache with store queue for Ex 2
endmodule


module mkDCacheLHUSM(WideMem mem, DCache ifc);
	// TODO: cache wht store queue and allows load hit under store miss for Ex 3
endmodule

