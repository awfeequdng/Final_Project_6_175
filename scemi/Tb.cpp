
#include <iostream>
#include <unistd.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "bsv_scemi.h"
#include "SceMiHeaders.h"
#include "ResetXactor.h"


// Initialize the memories from the given vmh file.
bool mem_init(const char *filename, InportProxyT<WideMemInit>& mem)
{
	WideMemInit msg; // msg to send

#ifdef MEM_INIT
	// TODO: read VMH with 64B per line
	fprintf(stderr, "ERROR: read VMH file not implemented\n");
	return false;
#endif

	// write done msg
    msg.the_tag = WideMemInit::tag_InitDone;
    mem.sendMessage(msg);

	return true;
}

int main(int argc, char* argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: TestDriver <vmh-file>\n");
        return 1;
    }

    int sceMiVersion = SceMi::Version( SCEMI_VERSION_STRING );
    SceMiParameters params("scemi.params");
    SceMi *sceMi = SceMi::Init(sceMiVersion, &params);

    // Initialize the SceMi ports
    InportProxyT<WideMemInit> mem("", "scemi_mem_inport", sceMi);
    OutportQueueT<ToHost> tohost("", "scemi_tohost_outport", sceMi);
    InportProxyT<FromHost> fromhost("", "scemi_fromhost_inport", sceMi);
    ResetXactor reset("", "scemi", sceMi);
    ShutdownXactor shutdown("", "scemi_shutdown", sceMi);

    // Service SceMi requests
    SceMiServiceThread *scemi_service_thread = new SceMiServiceThread(sceMi);

    // loop through all of the files in the command line
    for( int file_number = 1 ; file_number < argc ; file_number++ ) {
        // Reset the dut.
        reset.reset();

        // Get the VMH file to load.
        char* vmh = argv[file_number];
		fprintf(stderr, "---- %s ----\n", vmh);

        // Initialize the memories.
        if (!mem_init(vmh, mem)) {
            fprintf(stderr, "Failed to load memory\n");
            std::cout << "shutting down..." << std::endl;
            shutdown.blocking_send_finish();
            scemi_service_thread->stop();
            scemi_service_thread->join();
            SceMi::Shutdown(sceMi);
            std::cout << "finished" << std::endl;
            return 1;
        }

        // Start the core: start PC = 0x200
        fromhost.sendMessage(0x200);

        // Handle tohost requests.
		uint32_t print_int = 0; // integer to print
        while (true) {
            ToHost msg = tohost.getMessage();
			CpuToHostType::E_CpuToHostType type = msg.m_c2hType.m_val;
            uint16_t data = msg.m_data;

			if(type == CpuToHostType::e_ExitCode) {
				if(data == 0) {
					fprintf(stderr, "PASSED\n");
				} else {
					fprintf(stderr, "FAILED: exit code = %d\n", data);
				}
				break;
			} else if(type == CpuToHostType::e_PrintChar) {
				fprintf(stderr, "%c", (char)data);
			} else if(type == CpuToHostType::e_PrintIntLow) {
				print_int = uint32_t(data);
			} else if(type == CpuToHostType::e_PrintIntHigh) {
				print_int |= uint32_t(data) << 16;
				fprintf(stderr, "%d", print_int);
			}
        }
		fprintf(stderr, "\n");
    }

    shutdown.blocking_send_finish();
    scemi_service_thread->stop();
    scemi_service_thread->join();
    SceMi::Shutdown(sceMi);

    return 0;
}

