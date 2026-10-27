#include "DSCore.h"
#include "input.h"
#include <cstdio>
#include <string>
#include <cassert>
#include <chrono>
int main(int argc, char **argv){
 assert(argc==4);
 assert(ds_load(argv[1],argv[2],argv[3]));
 auto t=std::chrono::steady_clock::now();
 for(int i=0;i<120;i++)ds_run();
 printf("120 frames %.3fs top=%08x bottom=%08x\n",std::chrono::duration<double>(std::chrono::steady_clock::now()-t).count(),ds_pixels()[100*256+100],ds_pixels()[292*256+100]);
 unsigned before=ds_pixels()[100*256+100];
 ds_button(8,true);for(int i=0;i<5;i++)ds_run();
 unsigned after=ds_pixels()[100*256+100];
 printf("A button: %08x -> %08x\n",before,after);assert(before!=after);
 assert(ds_save_state((std::string(argv[3])+"/test.state").c_str()));ds_button(8,false);for(int i=0;i<5;i++)ds_run();
 assert(ds_load_state((std::string(argv[3])+"/test.state").c_str()));
 ds_touch(255,191,true);ds_run();assert(input_state.touch_x==255 && input_state.touch_y==191 && input_state.touching);ds_touch(0,0,false);ds_run();assert(!input_state.touching);ds_stop();
 puts("PASS load, frames, button, state roundtrip, touch, stop");
}
