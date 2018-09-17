local ffi = require('ffi')
local adt = require('adt')
local sdl = require('sdl2')
local util = require('util')
local sched = require('sched')
local trigger = require('trigger')

ffi.cdef [[

typedef int (*zz_audio_cb) (void *userdata, float *stream, int frames);

struct zz_audio_Device {
  zz_audio_cb callback;
  void *userdata;
};

void zz_audio_Device_cb(void *userdata, float *stream, int len);

/* Mixer */

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

int zz_audio_Mixer_cb (void *userdata, float *stream, int len);

/* SamplePlayer */

struct zz_audio_SamplePlayer {
  float *buf;
  int frames;
  int channels;
  int pos;
  int playing;
  zz_trigger end_signal;
};

int zz_audio_SamplePlayer_cb (void *userdata, float *stream, int len);

]]

local M = {}

function M.driver()
   return sdl.GetCurrentAudioDriver()
end

function M.devices()
   local count = sdl.GetNumAudioDevices()
   local index = 1
   local function _next()
      if index <= count then
         local device = {
            id = index,
            name = sdl.GetAudioDeviceName(index)
         }
         index = index + 1
         return device
      end
   end
   return _next
end

function M.Device(opts)
   opts = opts or {}
   opts.format = sdl.AUDIO_F32
   opts.channels = 2
   opts.callback = ffi.C.zz_audio_Device_cb
   assert(opts.source, "missing source")
   opts.userdata = ffi.new("struct zz_audio_Device")
   opts.userdata.callback = opts.source.callback
   opts.userdata.userdata = opts.source.userdata
   local dev = sdl.OpenAudioDevice(opts)
   if type(opts.source.setup) == "function" then
      opts.source:setup(dev.spec)
   end
   -- dev keeps references to callback, userdata and spec
   return dev
end

-- Mixer

local Mixer_mt = {}

function Mixer_mt:setup(audio_spec)
   self.userdata.buf = ffi.C.malloc(audio_spec.size)
end

function Mixer_mt:lock()
   util.check_ok("SDL_LockMutex", 0, sdl.SDL_LockMutex(self.userdata.mutex))
end

function Mixer_mt:unlock()
   util.check_ok("SDL_UnlockMutex", 0, sdl.SDL_UnlockMutex(self.userdata.mutex))
end

function Mixer_mt:add(source)
   assert(not self.sources:contains(source))
   local channel = ffi.new("struct zz_audio_MixerChannel")
   channel.callback = source.callback
   channel.userdata = source.userdata
   self:lock()
   channel.next = self.userdata.channels
   self.userdata.channels = channel
   self:unlock()
   self.sources:push(source)
   self.channels[source] = channel
end

function Mixer_mt:remove(source)
   assert(self.sources:contains(source))
   local channel = self.channels[source]
   assert(channel)
   local cur, prev = self.userdata.channels, nil
   while cur ~= nil do
      if cur == channel then
         self:lock()
         if prev ~= nil then
            prev.next = cur.next
         else
            self.userdata.channels = cur.next
         end
         self:unlock()
         break
      end
      prev = cur
      cur = cur.next
   end
   self.sources:remove(source)
   self.channels[source] = nil
   -- channel struct will be cleaned up by GC
end

function Mixer_mt:clear()
   self:lock()
   self.userdata.channels = nil
   self:unlock()
   self.sources:clear()
   self.channels = {}
end

function Mixer_mt:delete()
   if self.userdata.mutex ~= nil then
      sdl.SDL_DestroyMutex(self.userdata.mutex)
      self.userdata.mutex = nil
   end
   if self.userdata.buf ~= nil then
      ffi.C.free(self.userdata.buf)
      self.userdata.buf = nil
   end
   self.userdata.channels = nil
   self.sources:clear()
   self.channels = {}
end

Mixer_mt.__index = Mixer_mt

local function Mixer()
   local mixer = ffi.new("struct zz_audio_Mixer")
   mixer.mutex = sdl.SDL_CreateMutex()
   if mixer.mutex == nil then
      ef("SDL_CreateMutex() failed")
   end
   mixer.buf = nil -- will be created during setup
   local self = {
      callback = ffi.C.zz_audio_Mixer_cb,
      userdata = mixer,
      sources = adt.Set(),
      channels = {},
   }
   return setmetatable(self, Mixer_mt)
end

M.Mixer = Mixer

-- SamplePlayer

local SamplePlayer_mt = {}

function SamplePlayer_mt:playing(state)
   if state then
      self.userdata.playing = state
   end
   return self.userdata.playing
end

function SamplePlayer_mt:play()
   self:playing(1)
   return self.end_signal -- caller may poll it if needed
end

function SamplePlayer_mt:pause()
   self:playing(0)
end

function SamplePlayer_mt:lseek(offset, whence)
   local new_pos
   if whence == ffi.C.SEEK_CUR then
      new_pos = self.userdata.pos + offset
   elseif whence == ffi.C.SEEK_SET then
      new_pos = offset
   elseif whence == ffi.C.SEEK_END then
      new_pos = self.userdata.frames - offset
   end
   if new_pos >= 0 and new_pos <= self.userdata.frames then
      -- TODO: this should be atomic
      self.userdata.pos = new_pos
   end
end

function SamplePlayer_mt:seek(offset, relative)
   if relative then
      self:lseek(offset, ffi.C.SEEK_CUR)
   elseif offset >= 0 then
      self:lseek(offset, ffi.C.SEEK_SET)
   else
      self:lseek(offset, ffi.C.SEEK_END)
   end
end

function SamplePlayer_mt:delete()
   self.end_signal:delete()
end

SamplePlayer_mt.__index = SamplePlayer_mt

function M.SamplePlayer(opts)
   opts = opts or {}
   local player = ffi.new("struct zz_audio_SamplePlayer")
   player.buf = opts.buf
   player.frames = opts.frames
   player.channels = opts.channels
   player.pos = 0
   player.playing = 0
   local end_signal = trigger()
   player.end_signal = end_signal
   local self = {
      callback = ffi.C.zz_audio_SamplePlayer_cb,
      userdata = player,
      buf = opts.buf, -- keep a reference to prevent GC
      frames = tonumber(opts.frames),
      channels = opts.channels,
      end_signal = end_signal,
   }
   return setmetatable(self, SamplePlayer_mt)
end

return M
