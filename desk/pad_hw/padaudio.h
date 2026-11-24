// The Claude Pad's sound: the microphone and the speaker, through the ES8311 over I2S.
//
// Firmware only. A task on core 0 runs both directions in step, 20 ms at a time, 16 kHz, 16-bit:
//   in:  each 20 ms the microphone gives a frame; while recording, frames go to a queue that the
//        main loop sends to the Mac as text lines (A|id|seq|base64).
//   out: the speaker plays, in this order of precedence, nothing while recording, a test tone,
//        sound the Mac streamed in (PL| lines, into a 2 s ring), or the microphone (loopback test).
// The amplifier is switched on only while there is something to hear.
//
// Lines it handles and sends (the main loop passes them in and out; Serial stays the main loop's):
//   Mac -> pad   PL|<seq>|<base64 s16le mono>   sound to play; it starts once 200 ms is buffered
//                PE                             that is all: play what is left, then say PD|done
//                PX                             stop now; says PD|stopped
//   pad -> Mac   PK|<seq>|<ms buffered>         each PL| taken
//                PD|done / PD|stopped / PD|starved (nothing came for 3 s)
//                AS|<id>  A|<id>|<seq>|<base64>  AE|<id>|<frames>|<dropped>|<peak>|<why>
#pragma once
#include <Arduino.h>
#include <atomic>
#include <math.h>
#include "driver/i2s_std.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

namespace au {

struct Pins {
  int mclk = 4, bclk = 5, ws = 7, dout = 8, din = 6;   // dout: to the codec (speaker), din: from it (mic)
  int amp = 1;
  bool ampOnLow = true;                                // the amplifier is on while its pin is low
};
inline Pins pins;

const int RATE = 16000;
const int FRAME = 320;                 // 20 ms
const uint32_t RING = 32768;           // 2 s of playback
const int START_SAMPLES = 3200;        // 200 ms buffered before playback starts
const int QUEUE = 50;                  // 1 s of microphone frames

struct MicFrame {
  uint32_t seq;
  int16_t peak;
  int16_t s[FRAME];
};

inline i2s_chan_handle_t tx = nullptr, rx = nullptr;
inline QueueHandle_t micQueue = nullptr;
inline TaskHandle_t task = nullptr;
inline int16_t *ring = nullptr;

inline std::atomic<bool> running{false};
inline std::atomic<bool> recording{false};
inline std::atomic<uint32_t> micSeq{0}, micDropped{0};
inline std::atomic<int> micPeak{0};             // loudest sample of the recording so far
inline std::atomic<int> level{0};               // loudest sample of the latest 20 ms, 0..32767
inline std::atomic<int> peakL{0}, peakR{0};     // the same, per I2S slot (which one is the mic?)
inline std::atomic<int> slot{0};                // 0 left, 1 right, 2 both mixed
inline std::atomic<uint32_t> head{0}, tail{0};  // ring: head is written by the main loop, tail by the task
inline std::atomic<bool> playing{false}, ending{false};
inline std::atomic<uint32_t> fedAt{0};          // millis() of the last PL| line
inline std::atomic<int> finished{0};            // 1 done, 2 stopped, 3 starved: for poll() to report
inline std::atomic<int> toneHz{0}, toneLeft{0}, toneVolume{30};
inline std::atomic<bool> loopback{false};
inline std::atomic<uint32_t> heardAt{0};        // millis() of the last sound sent to the speaker
inline std::atomic<uint32_t> readErrors{0};

inline uint32_t recId = 0;
inline uint32_t recStarted = 0;

inline void amp(bool on) {
  if (pins.amp < 0) return;
  digitalWrite(pins.amp, on == pins.ampOnLow ? LOW : HIGH);
}

inline uint32_t buffered() { return head.load() - tail.load(); }

inline void runTask(void *) {
  static int16_t in[FRAME * 2], out[FRAME * 2];
  static MicFrame frame;
  float phase = 0;
  bool ampOn = false;
  while (running) {
    size_t got = 0;
    if (i2s_channel_read(rx, in, sizeof in, &got, 200) != ESP_OK || got < sizeof in) {
      readErrors++;
      memset(in, 0, sizeof in);
    }
    int pl = 0, pr = 0, pm = 0, which = slot;
    for (int i = 0; i < FRAME; i++) {
      int l = in[2 * i], r = in[2 * i + 1];
      pl = max(pl, abs(l));
      pr = max(pr, abs(r));
      int16_t m = (int16_t)(which == 0 ? l : which == 1 ? r : (l + r) / 2);
      frame.s[i] = m;
      pm = max(pm, abs((int)m));
    }
    peakL = pl;
    peakR = pr;
    level = pm;
    if (recording) {
      frame.seq = micSeq++;
      frame.peak = (int16_t)min(pm, 32767);
      if (pm > micPeak) micPeak = pm;
      if (xQueueSend(micQueue, &frame, 0) != pdTRUE) micDropped++;
    }

    bool sound = false;
    const bool rec = recording;
    for (int i = 0; i < FRAME; i++) {
      int16_t v = 0;
      if (rec) {
        // silent: the speaker would be heard by the microphone
      } else if (toneLeft > 0) {
        v = (int16_t)(sinf(phase) * 327.67f * toneVolume);
        phase += 2 * (float)M_PI * toneHz / RATE;
        if (phase > 2 * (float)M_PI) phase -= 2 * (float)M_PI;
        toneLeft--;
        sound = true;
      } else if (playing) {
        if (tail.load() != head.load()) {
          v = ring[tail.load() % RING];
          tail++;
          sound = true;
        } else if (ending) {
          playing = false;
          ending = false;
          finished = 1;
        }
      } else if (loopback) {
        v = frame.s[i];
        sound = true;
      }
      out[2 * i] = out[2 * i + 1] = v;
    }
    if (playing && !ending && buffered() == 0 && millis() - fedAt > 3000) {
      playing = false;
      finished = 3;
    }
    if (sound) heardAt = millis();
    bool want = sound || millis() - heardAt < 300;
    if (want != ampOn) {
      amp(want);
      ampOn = want;
    }
    size_t put = 0;
    i2s_channel_write(tx, out, sizeof out, &put, 200);
  }
  amp(false);
  task = nullptr;
  vTaskDelete(nullptr);
}

inline void end() {
  if (running) {
    running = false;
    for (int i = 0; i < 50 && task; i++) delay(10);
  }
  if (tx) { i2s_channel_disable(tx); i2s_del_channel(tx); tx = nullptr; }
  if (rx) { i2s_channel_disable(rx); i2s_del_channel(rx); rx = nullptr; }
}

// Starts I2S (and so the codec's MCLK) and the audio task. false and a reason when it cannot.
inline bool begin(String &why) {
  end();
  if (pins.amp >= 0) {
    pinMode(pins.amp, OUTPUT);
    amp(false);
  }
  if (!ring) ring = (int16_t *)ps_malloc(RING * sizeof(int16_t));
  if (!ring) ring = (int16_t *)malloc(RING * sizeof(int16_t));
  if (!micQueue) micQueue = xQueueCreate(QUEUE, sizeof(MicFrame));
  if (!ring || !micQueue) { why = "no memory"; return false; }

  i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
  cc.auto_clear = true;
  cc.dma_desc_num = 6;
  cc.dma_frame_num = 240;
  if (i2s_new_channel(&cc, &tx, &rx) != ESP_OK) { why = "i2s channel"; return false; }

  i2s_std_config_t sc = {};
  sc.clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(RATE);
  sc.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
  sc.slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
  sc.gpio_cfg.mclk = (gpio_num_t)pins.mclk;
  sc.gpio_cfg.bclk = (gpio_num_t)pins.bclk;
  sc.gpio_cfg.ws = (gpio_num_t)pins.ws;
  sc.gpio_cfg.dout = (gpio_num_t)pins.dout;
  sc.gpio_cfg.din = (gpio_num_t)pins.din;
  if (i2s_channel_init_std_mode(tx, &sc) != ESP_OK || i2s_channel_init_std_mode(rx, &sc) != ESP_OK) {
    why = "i2s setup";
    end();
    return false;
  }
  i2s_channel_enable(tx);
  i2s_channel_enable(rx);
  running = true;
  if (xTaskCreatePinnedToCore(runTask, "audio", 8192, nullptr, 5, &task, 0) != pdPASS) {
    running = false;
    why = "audio task";
    end();
    return false;
  }
  return true;
}

// ---------- base64 ----------
inline const char *B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

inline size_t encode(const uint8_t *in, size_t n, char *out) {
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    uint32_t v = in[i] << 16 | (i + 1 < n ? in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
    out[o++] = B64[v >> 18 & 63];
    out[o++] = B64[v >> 12 & 63];
    out[o++] = i + 1 < n ? B64[v >> 6 & 63] : '=';
    out[o++] = i + 2 < n ? B64[v & 63] : '=';
  }
  out[o] = 0;
  return o;
}

inline int b64value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

// Decodes until the end or a character that is not base64. Returns the bytes written.
inline size_t decode(const char *in, uint8_t *out, size_t room) {
  size_t o = 0;
  uint32_t v = 0;
  int bits = 0;
  for (; *in; in++) {
    int d = b64value(*in);
    if (d < 0) break;
    v = v << 6 | d;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (o < room) out[o++] = (uint8_t)(v >> bits & 0xFF);
    }
  }
  return o;
}

// ---------- the main loop's side ----------

inline void tone(int hz, int ms, int vol = 30) {
  toneVolume = vol;
  toneHz = hz;
  toneLeft = RATE * ms / 1000;
}

inline void stopPlaying() {
  playing = false;
  ending = false;
  tail.store(head.load());
}

inline void startRecording(Print &out, uint32_t id) {
  stopPlaying();
  toneLeft = 0;
  xQueueReset(micQueue);
  micSeq = 0;
  micDropped = 0;
  micPeak = 0;
  recId = id;
  recStarted = millis();
  recording = true;
  out.printf("AS|%lu\n", (unsigned long)id);
}

// Sends up to max waiting microphone frames as A| lines. Returns how many it sent.
inline int sendMic(Print &out, int max = 4) {
  static char text[FRAME * 2 * 4 / 3 + 8];
  MicFrame f;
  int n = 0;
  while (n < max && xQueueReceive(micQueue, &f, 0) == pdTRUE) {
    encode((const uint8_t *)f.s, sizeof f.s, text);
    out.printf("A|%lu|%lu|%s\n", (unsigned long)recId, (unsigned long)f.seq, text);
    n++;
  }
  return n;
}

inline void stopRecording(Print &out, const char *why) {
  if (!recording) return;
  recording = false;
  delay(25);                     // the frame in flight
  while (sendMic(out, 8)) {
  }
  out.printf("AE|%lu|%lu|%lu|%d|%s\n", (unsigned long)recId, (unsigned long)micSeq.load(),
             (unsigned long)micDropped.load(), micPeak.load(), why);
}

inline void cancelRecording(Print &out) {
  if (!recording) return;
  recording = false;
  xQueueReset(micQueue);
  out.printf("AE|%lu|%lu|%lu|%d|cancel\n", (unsigned long)recId, (unsigned long)micSeq.load(),
             (unsigned long)micDropped.load(), micPeak.load());
}

// PL|, PE and PX lines. true when the line was one of them.
inline bool playLine(const char *line, Print &out) {
  if (!strcmp(line, "PE")) {
    if (playing || buffered()) {
      playing = true;
      ending = true;
    } else {
      out.println("PD|done");
    }
    return true;
  }
  if (!strcmp(line, "PX")) {
    bool was = playing || buffered();
    stopPlaying();
    finished = 0;
    out.println(was ? "PD|stopped" : "PD|done");
    return true;
  }
  if (strncmp(line, "PL|", 3)) return false;
  unsigned long seq = strtoul(line + 3, nullptr, 10);
  const char *b64 = strchr(line + 3, '|');
  if (!b64) return true;
  static uint8_t bytes[2048];
  size_t n = decode(b64 + 1, bytes, sizeof bytes) / 2;
  const int16_t *s = (const int16_t *)bytes;
  for (size_t i = 0; i < n && buffered() < RING - 1; i++) {
    ring[head.load() % RING] = s[i];
    head++;
  }
  fedAt = millis();
  if (!playing && !recording && buffered() >= (uint32_t)START_SAMPLES) playing = true;
  out.printf("PK|%lu|%lu\n", seq, (unsigned long)(buffered() * 1000 / RATE));
  return true;
}

// Reports playback that ended by itself. Call it every loop.
inline void poll(Print &out) {
  int f = finished.exchange(0);
  if (f == 1) out.println("PD|done");
  if (f == 3) out.println("PD|starved");
}

}  // namespace au
