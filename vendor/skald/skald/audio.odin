package skald

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import sdl3 "vendor:sdl3"

// audio.odin — microphone capture + PCM playback, wrapping SDL3's
// core audio API (the same `vendor:sdl3` dependency Skald already
// links for the window). No `sdl3/mixer` — this is the raw device +
// stream layer, which is enough for recording a voice clip and
// playing one back.
//
// Samples are 32-bit float (`f32`), the friendliest format to work
// with in Odin and what Opus / most codecs want anyway. SDL converts
// between the device's native format and f32 inside the stream, so
// callers always see f32 regardless of hardware.
//
// Scope: capture + playback of raw PCM. Encoding / decoding (Opus,
// etc.) is the app's job — Skald stays at one C dependency (SDL3).
// A voice-message flow is: capture → app-side opus_encode → send;
// receive → app-side opus_decode → playback.
//
// Threading: SDL runs the actual device on its own thread. The
// `AudioStream` push/pull calls are internally locked, so the
// polling API below (call `audio_capture_read` / `audio_play_write`
// from your update loop or a timer) is safe without app-side locks.

// The audio subsystem is initialised lazily on the first capture or
// playback open, so apps that never touch audio pay nothing — Skald's
// own `SDL_Init` only requests `{.VIDEO}`.
@(private) g_audio_ready: bool

@(private)
audio_ensure_subsystem :: proc() -> bool {
	if g_audio_ready { return true }
	if !sdl3.InitSubSystem({.AUDIO}) {
		fmt.eprintfln("skald: SDL audio subsystem init failed: %s", sdl3.GetError())
		return false
	}
	g_audio_ready = true
	return true
}

// Audio_Device is one enumerated capture (or playback) device.
// `id` is the SDL handle to pass to `audio_capture_open` /
// `audio_play_open`; `name` is a human-readable label for a device
// picker UI. `name` is cloned into the caller's allocator.
Audio_Device :: struct {
	id:   u32,
	name: string,
}

// Audio_Capture is an open recording stream. Opaque — pass the
// pointer to `audio_capture_read` / `audio_capture_close`.
Audio_Capture :: struct {
	stream: ^sdl3.AudioStream,
	device: sdl3.AudioDeviceID,
	rate:   int,
}

// Audio_Playback is an open playback stream.
Audio_Playback :: struct {
	stream: ^sdl3.AudioStream,
	device: sdl3.AudioDeviceID,
	rate:   int,
}

// audio_capture_devices enumerates connected microphones. Returns a
// slice of Audio_Device allocated into `allocator` (default temp);
// each `name` is cloned into the same allocator. Drive a device-picker
// dropdown (`select` / `combobox`) from the result, store the chosen
// `id`, and pass it to `audio_capture_open`. The default system mic
// is also reachable without enumeration by passing device id 0.
audio_capture_devices :: proc(allocator := context.temp_allocator) -> []Audio_Device {
	if !audio_ensure_subsystem() { return nil }
	count: c.int
	ids := sdl3.GetAudioRecordingDevices(&count)
	return audio_devices_from_ids(ids, count, allocator)
}

// audio_playback_devices enumerates connected output devices
// (speakers, headphones, HDMI sinks). Same shape as
// `audio_capture_devices` — feed it to a picker, pass the chosen `id`
// to `audio_play_open`. Device id 0 = default system output.
audio_playback_devices :: proc(allocator := context.temp_allocator) -> []Audio_Device {
	if !audio_ensure_subsystem() { return nil }
	count: c.int
	ids := sdl3.GetAudioPlaybackDevices(&count)
	return audio_devices_from_ids(ids, count, allocator)
}

@(private)
audio_devices_from_ids :: proc(ids: [^]sdl3.AudioDeviceID, count: c.int, allocator: mem.Allocator) -> []Audio_Device {
	if ids == nil || count <= 0 { return nil }
	defer sdl3.free(ids)
	out := make([]Audio_Device, int(count), allocator)
	for i in 0..<int(count) {
		id := ids[i]
		name := sdl3.GetAudioDeviceName(id)
		out[i] = Audio_Device{
			id   = u32(id),
			name = strings.clone(string(name) if name != nil else "", allocator),
		}
	}
	return out
}

// audio_capture_open opens a recording stream and starts capturing.
// `device_id` of 0 means the default system microphone. `rate` is
// the sample rate you want samples delivered at (48000 is the Opus
// voice default); `channels` is 1 for mono (right for voice) or 2
// for stereo. Returns the handle + true on success.
//
// The stream begins capturing immediately — call `audio_capture_read`
// from your update loop / a timer to pull samples as they arrive.
audio_capture_open :: proc(
	device_id: u32 = 0,
	rate:      int = 48000,
	channels:  int = 1,
) -> (^Audio_Capture, bool) {
	if !audio_ensure_subsystem() { return nil, false }
	dev := sdl3.AudioDeviceID(device_id)
	if dev == 0 { dev = sdl3.AUDIO_DEVICE_DEFAULT_RECORDING }

	spec := sdl3.AudioSpec{
		format   = .F32,
		channels = c.int(channels),
		freq     = c.int(rate),
	}
	stream := sdl3.OpenAudioDeviceStream(dev, &spec, nil, nil)
	if stream == nil {
		fmt.eprintfln("skald: OpenAudioDeviceStream (recording) failed: %s", sdl3.GetError())
		return nil, false
	}
	// Opened streams start paused — resume to begin capturing.
	if !sdl3.ResumeAudioStreamDevice(stream) {
		fmt.eprintfln("skald: ResumeAudioStreamDevice (recording) failed: %s", sdl3.GetError())
		sdl3.DestroyAudioStream(stream)
		return nil, false
	}
	cap := new(Audio_Capture)
	cap.stream = stream
	cap.device = sdl3.GetAudioStreamDevice(stream)
	cap.rate   = rate
	return cap, true
}

// audio_capture_available returns how many f32 samples are queued and
// ready to pull. Useful to size a read buffer or decide whether to
// drain this frame.
audio_capture_available :: proc(cap: ^Audio_Capture) -> int {
	if cap == nil || cap.stream == nil { return 0 }
	return int(sdl3.GetAudioStreamAvailable(cap.stream)) / size_of(f32)
}

// audio_capture_read pulls up to `len(into)` captured f32 samples into
// `into`, returning the number actually written (0 when nothing is
// queued yet). Non-blocking — call it repeatedly to drain the mic.
audio_capture_read :: proc(cap: ^Audio_Capture, into: []f32) -> int {
	if cap == nil || cap.stream == nil || len(into) == 0 { return 0 }
	want := c.int(len(into) * size_of(f32))
	got  := sdl3.GetAudioStreamData(cap.stream, raw_data(into), want)
	if got <= 0 { return 0 }
	return int(got) / size_of(f32)
}

// audio_capture_close stops capturing and frees the stream + handle.
audio_capture_close :: proc(cap: ^Audio_Capture) {
	if cap == nil { return }
	if cap.stream != nil { sdl3.DestroyAudioStream(cap.stream) }
	free(cap)
}

// audio_play_open opens a playback stream for queueing PCM. `rate` /
// `channels` describe the format of the f32 samples you'll write;
// SDL resamples / reformats to the device. `device_id` 0 = default
// speaker. Begins ready to play — write samples and they're heard as
// soon as the device pulls them.
audio_play_open :: proc(
	device_id: u32 = 0,
	rate:      int = 48000,
	channels:  int = 1,
) -> (^Audio_Playback, bool) {
	if !audio_ensure_subsystem() { return nil, false }
	dev := sdl3.AudioDeviceID(device_id)
	if dev == 0 { dev = sdl3.AUDIO_DEVICE_DEFAULT_PLAYBACK }

	spec := sdl3.AudioSpec{
		format   = .F32,
		channels = c.int(channels),
		freq     = c.int(rate),
	}
	stream := sdl3.OpenAudioDeviceStream(dev, &spec, nil, nil)
	if stream == nil {
		fmt.eprintfln("skald: OpenAudioDeviceStream (playback) failed: %s", sdl3.GetError())
		return nil, false
	}
	if !sdl3.ResumeAudioStreamDevice(stream) {
		fmt.eprintfln("skald: ResumeAudioStreamDevice (playback) failed: %s", sdl3.GetError())
		sdl3.DestroyAudioStream(stream)
		return nil, false
	}
	pb := new(Audio_Playback)
	pb.stream = stream
	pb.device = sdl3.GetAudioStreamDevice(stream)
	pb.rate   = rate
	return pb, true
}

// audio_play_write queues `samples` (f32) for playback. Returns true
// on success. Queue as much or as little as you like — SDL buffers
// it and plays it out at the device rate. For a one-shot voice clip,
// write the whole decoded buffer once and poll `audio_play_queued`
// to know when it's finished.
audio_play_write :: proc(pb: ^Audio_Playback, samples: []f32) -> bool {
	if pb == nil || pb.stream == nil || len(samples) == 0 { return false }
	return sdl3.PutAudioStreamData(pb.stream, raw_data(samples),
		c.int(len(samples) * size_of(f32)))
}

// audio_play_queued returns how many f32 samples are still waiting to
// be played. Poll it after writing a clip to detect playback finish
// (reaches 0). Drives a progress bar by comparing against the total
// written.
audio_play_queued :: proc(pb: ^Audio_Playback) -> int {
	if pb == nil || pb.stream == nil { return 0 }
	return int(sdl3.GetAudioStreamQueued(pb.stream)) / size_of(f32)
}

// audio_play_close stops playback and frees the stream + handle. Any
// un-played queued samples are discarded.
audio_play_close :: proc(pb: ^Audio_Playback) {
	if pb == nil { return }
	if pb.stream != nil { sdl3.DestroyAudioStream(pb.stream) }
	free(pb)
}
