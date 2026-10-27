#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
bool ds_load(const char *rom, const char *system, const char *saves);
void ds_stop(void);
void ds_run(void);
const uint32_t *ds_pixels(void);
void ds_button(unsigned button, bool pressed);
void ds_touch(int x, int y, bool pressed);
void ds_clear_input(void);
void ds_audio(float *left, float *right, unsigned frames);
bool ds_save_state(const char *path);
bool ds_load_state(const char *path);
#ifdef __cplusplus
}
#endif
