#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <SDL2/SDL_audio.h>
#include <SDL2/SDL_mutex.h>

#include "audio.h"
#include "trigger.h"

#define MIN(x,y) (((x) < (y)) ? (x) : (y))

struct zz_audio_Device {
  zz_audio_cb callback;
  void *userdata;
};

void zz_audio_Device_cb(void *userdata, float *stream, int len) {
  struct zz_audio_Device *dev = (struct zz_audio_Device *) userdata;
  int filled = dev->callback(dev->userdata, stream, len);
  if (!filled) {
    memset(stream, 0, len);
  }
}

struct zz_audio_MixerChannel {
  zz_audio_cb callback;
  void *userdata;
  struct zz_audio_MixerChannel *next;
};

struct zz_audio_Mixer {
  SDL_mutex *mutex;
  float *buf; /* temp buffer for output of channels */
  struct zz_audio_MixerChannel *channels;
};

int zz_audio_Mixer_cb (void *userdata, float *stream, int len) {
  struct zz_audio_Mixer *mixer = (struct zz_audio_Mixer *) userdata;
  if (!mixer->channels) return 0;
  memset(stream, 0, len);
  if (SDL_LockMutex(mixer->mutex) != 0) {
    fprintf(stderr, "zz_audio_Mixer_cb: SDL_LockMutex() failed\n");
    exit(1);
  }
  struct zz_audio_MixerChannel *ch = mixer->channels;
  while (ch != NULL) {
    int filled = ch->callback(ch->userdata, mixer->buf, len);
    if (filled) {
      int n = len / sizeof(float);
      for (int i=0; i<n; i++) {
        stream[i] += mixer->buf[i];
      }
    }
    ch = ch->next;
  }
  if (SDL_UnlockMutex(mixer->mutex) != 0) {
    fprintf(stderr, "zz_audio_Mixer_cb: SDL_UnlockMutex() failed\n");
    exit(1);
  }
  return 1;
}

struct zz_audio_SamplePlayer {
  float *buf; /* array of float samples */
  int frames;
  int channels;
  int pos;
  int playing; /* 1: playing, 0: paused */
  zz_trigger end_signal; /* triggered at end of sample */
};

int zz_audio_SamplePlayer_cb (void *userdata, float *stream, int len) {
  struct zz_audio_SamplePlayer *player = (struct zz_audio_SamplePlayer *) userdata;
  int frames = len / (2 * sizeof(float));
  if (player->pos < 0) player->pos = 0;
  if (player->pos > player->frames) player->pos = player->frames;
  if (player->playing != 0 && player->pos == player->frames) {
    player->playing = 0;
  }
  if (player->playing == 0) {
    return 0;
  }
  /* frame_count: how many sample frames to copy into stream */
  int frame_count = MIN(player->frames - player->pos, frames);
  /* zero_count: how many zero frames to copy into stream */
  int zero_count = frames - frame_count;
  float *src = player->buf + player->pos * player->channels;
  float *dst = stream;
  switch (player->channels) {
  case 2:
    memcpy(dst, src, 2 * frame_count * sizeof(float));
    src += 2 * frame_count;
    dst += 2 * frame_count;
    break;
  case 1:
    for (int i=0; i<frame_count; i++) {
      float sample = *(src++);
      *(dst++) = sample;
      *(dst++) = sample;
    }
    break;
  default:
    fprintf(stderr, "unsupported number of sample channels: %d\n", player->channels);
    exit(1);
  }
  if (zero_count > 0) {
    memset(dst, 0, 2 * zero_count * sizeof(float));
  }
  player->pos += frame_count;
  if (player->pos >= player->frames) {
    zz_trigger_fire(&player->end_signal);
  }
  return 1;
}
