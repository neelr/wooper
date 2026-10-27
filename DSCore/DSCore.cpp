#include "DSCore.h"
#include "libretro.h"
#include <atomic>
#include <vector>
#include <string>
#include <fstream>
#include <cstring>
#include <map>
#include <cstdio>
#include <algorithm>

static std::string systemDir, saveDir, romPath;
static std::vector<char> romData;
static retro_game_info game;
static bool running = false, initialized = false;
static uint32_t pixels[256 * 384] = {};
static std::atomic<unsigned> buttons{0};
static std::atomic<int> touchX{0}, touchY{0};
static std::atomic<bool> touching{false};
static constexpr unsigned capacity = 32768;
static float audioRing[capacity * 2];
static std::atomic<unsigned> readPos{0}, writePos{0};
static std::map<std::string,std::string> defaults;

static bool environment(unsigned cmd, void *data) {
    switch(cmd) {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char**)data=systemDir.c_str(); return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char**)data=saveDir.c_str(); return true;
        case RETRO_ENVIRONMENT_GET_USERNAME: *(const char**)data="Wooper"; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: return *(retro_pixel_format*)data == RETRO_PIXEL_FORMAT_XRGB8888;
        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *(unsigned*)data=0; return true;
        case RETRO_ENVIRONMENT_SET_VARIABLES: {
            auto v=(retro_variable*)data;
            for(;v && v->key;v++) { std::string s=v->value; auto p=s.find("; "); if(p!=std::string::npos) { s=s.substr(p+2); defaults[v->key]=s.substr(0,s.find('|')); } }
            return true;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            auto v=(retro_variable*)data;
            static const std::map<std::string,std::string> opts={
                {"melonds_console_mode","DS"},{"melonds_boot_directly","enabled"},
                {"melonds_screen_layout","Top/Bottom"},{"melonds_screen_gap","0"},
                {"melonds_touch_mode","Touch"},{"melonds_use_fw_settings","disabled"},
                {"melonds_threaded_renderer","enabled"},{"melonds_opengl_renderer","disabled"},
                {"melonds_jit_enable","disabled"}
            };
            auto it=opts.find(v->key); if(it!=opts.end()) {v->value=it->second.c_str();return true;}
            auto d=defaults.find(v->key);v->value=d!=defaults.end()?d->second.c_str():nullptr;return v->value!=nullptr;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool*)data=false; return true;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_GEOMETRY:
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: return true;
        default: return false;
    }
}
static void video(const void *p,unsigned w,unsigned h,size_t pitch) {
    if(!p || p==RETRO_HW_FRAME_BUFFER_VALID || w!=256 || h!=384) return;
    for(unsigned y=0;y<h;y++) memcpy(pixels+y*256,(const char*)p+y*pitch,1024);
}
static size_t audioBatch(const int16_t *data,size_t frames) {
    unsigned w=writePos.load(std::memory_order_relaxed),r=readPos.load(std::memory_order_acquire);
    size_t count=std::min(frames,(size_t)(capacity-(w-r)));
    for(size_t i=0;i<count;i++) {unsigned p=((w+i)%capacity)*2;audioRing[p]=data[2*i]/32768.f;audioRing[p+1]=data[2*i+1]/32768.f;}
    writePos.store(w+(unsigned)count,std::memory_order_release);return frames;
}
static void audioSample(int16_t l,int16_t r) {int16_t p[]={l,r};audioBatch(p,1);}
static void poll() {}
static int16_t input(unsigned port,unsigned device,unsigned index,unsigned id) {
    if(port) return 0;
    if(device==RETRO_DEVICE_JOYPAD) return id==RETRO_DEVICE_ID_JOYPAD_MASK?(int16_t)buttons.load():(buttons.load()>>id)&1;
    if(device==RETRO_DEVICE_POINTER) {
        if(id==RETRO_DEVICE_ID_POINTER_PRESSED) return touching.load();
        if(id==RETRO_DEVICE_ID_POINTER_X) return (int16_t)((2*touchX.load()+1)*65536/512-32768);
        if(id==RETRO_DEVICE_ID_POINTER_Y) return (int16_t)((2*(touchY.load()+192)+1)*65536/768-32768);
    }
    return 0;
}
bool ds_load(const char *path,const char *sys,const char *save) {
    ds_stop(); systemDir=sys;saveDir=save;romPath=path;
    std::ifstream f(path,std::ios::binary);if(!f)return false;
    f.seekg(0,std::ios::end); auto length=f.tellg();
    if(length<512 || length>512*1024*1024)return false;
    f.seekg(0);romData.assign(std::istreambuf_iterator<char>(f),{});
    auto word=[](size_t p)->uint64_t {auto d=(const uint8_t*)romData.data();return uint64_t(d[p])|(uint64_t(d[p+1])<<8)|(uint64_t(d[p+2])<<16)|(uint64_t(d[p+3])<<24);};
    for(size_t p:{0x20,0x30})if(word(p)<512||word(p+12)==0||word(p)+word(p+12)>romData.size())return false;
    retro_set_environment(environment);retro_set_video_refresh(video);retro_set_audio_sample(audioSample);
    retro_set_audio_sample_batch(audioBatch);retro_set_input_poll(poll);retro_set_input_state(input);
    retro_init();initialized=true;game={romPath.c_str(),romData.data(),romData.size(),nullptr};
    running=retro_load_game(&game);return running;
}
void ds_stop() {if(running)retro_unload_game();if(initialized)retro_deinit();running=false;initialized=false;ds_clear_input();memset(pixels,0,sizeof pixels);}
void ds_run() {if(running)retro_run();}
const uint32_t *ds_pixels(){return pixels;}
void ds_button(unsigned b,bool pressed){if(b>15)return;if(pressed)buttons.fetch_or(1u<<b);else buttons.fetch_and(~(1u<<b));}
void ds_touch(int x,int y,bool p){touchX=std::clamp(x,0,255);touchY=std::clamp(y,0,191);touching=p;}
void ds_clear_input(){buttons=0;touching=false;}
void ds_audio(float *l,float *r,unsigned frames){unsigned pos=readPos.load(std::memory_order_relaxed),w=writePos.load(std::memory_order_acquire);for(unsigned i=0;i<frames;i++){if(pos!=w){unsigned p=(pos++%capacity)*2;l[i]=audioRing[p];r[i]=audioRing[p+1];}else{l[i]=0;r[i]=0;}}readPos.store(pos,std::memory_order_release);}
bool ds_save_state(const char *path) {
    if(!running)return false;
    size_t n=retro_serialize_size();if(n==0||n>32*1024*1024)return false;
    std::vector<char>d(n);if(!retro_serialize(d.data(),n))return false;
    std::string temp=std::string(path)+".tmp";
    std::ofstream f(temp,std::ios::binary);f.write(d.data(),n);f.close();
    if(!f.good()){std::remove(temp.c_str());return false;}
    return std::rename(temp.c_str(),path)==0;
}
bool ds_load_state(const char *path) {
    if(!running)return false;
    std::ifstream f(path,std::ios::binary);if(!f)return false;
    f.seekg(0,std::ios::end);auto n=f.tellg();if(n<=0||n>32*1024*1024)return false;
    f.seekg(0);std::vector<char>d((std::istreambuf_iterator<char>(f)),{});
    return retro_unserialize(d.data(),d.size());
}
