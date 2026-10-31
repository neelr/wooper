#include "DSCore.h"
#include <cassert>
#include <cstdio>
#include <string>
int main(int argc, char **argv) {
    assert(argc == 5);
    // A fresh core has no timing-table pointers from earlier gameplay.
    for (int launch = 0; launch < 2; ++launch) {
        assert(ds_load(argv[1], argv[3], argv[4]));
        assert(ds_load_state(argv[2]));
        for (int frame = 0; frame < 600; ++frame) ds_run();
        auto checkpoint = std::string(argv[4]) + "/resume.state";
        assert(ds_save_state(checkpoint.c_str()));
        ds_stop();
        assert(ds_load(argv[1], argv[3], argv[4]));
        assert(ds_load_state(checkpoint.c_str()));
        for (int frame = 0; frame < 120; ++frame) ds_run();
        ds_stop();
    }
    puts("PASS fresh-core resume, 1200 frames, save and reopen twice");
}
