# Voice

Sora treats voice as two separate capabilities so unsupported chat models do
not make basic dictation disappear.

## Dictation

Dictation uses macOS Speech Recognition and is independent of the selected AI
provider or model. The microphone button records only while visibly active and
transcribes into editable input. It never presses Return or sends a request:
the user reviews and submits the text normally.

- In Terminal, the completed transcript is inserted at the current prompt. It
  can contain ordinary shell input or an `/agent` request.
- In Agent, partial transcripts appear directly in the composer and preserve
  text that was already present.
- Microphone and Speech Recognition permissions are requested only on first
  use. Denial produces a visible explanation.

## Realtime voice conversation

Realtime conversation is a separate, optional OpenAI API path. It streams
24 kHz PCM microphone audio over a Realtime WebSocket, uses semantic voice
activity detection to end turns, and plays the model's PCM response as it
arrives. User and assistant transcripts stream into the active tab's Agent
history and remain there after the call ends.

Sora currently starts with separate ordinary microphone and playback engines.
Microphone upload remains active during playback, allowing interruptions.
A headphone notice is displayed because echo cancellation is unavailable on
this path. VoiceProcessingIO startup is disabled pending hardware validation:
on the tested macOS route it delivered digital silence, faulted its downlink
processor, and left repeated aggregate-device changes during teardown.
Raw capture installs its tap at the hardware input format and converts to
24 kHz for upload; it does not reuse a potentially stale client output format.

The Voice Settings page owns a separate Realtime model choice, initially
`gpt-realtime-2.1`. The waveform control is enabled only when Agent is on, the
OpenAI API provider is selected, and that model is in the verified capability
list in `AIBackend.swift`. Codex sign-in, Anthropic, Grok, Gateway, and ordinary
text models remain disabled unless a provider-specific implementation is added
and verified.

Realtime voice intentionally exposes no tools. Its session instructions state
that it cannot run commands, and voice output bypasses command-envelope parsing.
To run a terminal action, the user sends a typed request through Agent so the
existing command proposal and approval layer remains authoritative.

Leaving Agent or changing provider ends the voice session and releases the
microphone. Speaking while Sora is playing stops
queued audio and truncates the unplayed response in the server conversation.
The truncation point uses the player's actual clock and is capped just inside
the duration of PCM audio received for that response, because the Realtime API
rejects timestamps beyond the available audio. Completed playback is cleared
from interruption tracking so the next user turn cannot truncate an already
heard response. The waveform or End control always stops the session.

Playback callbacks from stopped audio are ignored so they cannot drain the next
response's buffer count. An interruption before playback begins truncates at
zero milliseconds. The server cancels generation when VAD detects speech;
Sora stops local playback and truncates the unheard audio as described in the
[OpenAI Realtime guide](https://developers.openai.com/api/docs/guides/realtime-conversations#handling-interruptions).

Manual regression check: start a voice conversation, ask for a long answer,
and speak a new question while it plays. Confirm playback stops promptly, the
new question is transcribed, and the next reply plays normally. Repeat with
built-in speakers and with headphones; if echo cancellation is unavailable,
verify the headphone notice appears and input remains active.

Capture startup is checked after five seconds using delivered PCM. If voice
processing delivers no buffers or only digital zero, Sora retries without
voice processing and shows the headphone notice. This covers audio-processing
faults that happen after AVAudioEngine.start succeeds. Raw capture that delivers
no buffers produces a visible error; ordinary silence on a working raw input is
allowed. Conversion and microphone-upload errors end the call visibly.

Audio configuration changes can stop AVAudioEngine asynchronously and invalidate
its tap. Recovery removes the old observer/tap and disables voice processing
before building a replacement engine, allowing 750 ms for aggregate-device
teardown. Configuration-change notifications trigger the same bounded recovery
(maximum three attempts per call). Startup capture and recovery counts are logged
without audio, transcripts, or credentials.

The non-voice-processed fallback uses separate input-only and output-only
AVAudioEngines. A single raw duplex engine creates a Core Audio aggregate device;
on mixed-rate routes, this caused recurring configuration changes and stale
24 kHz client formats against a 48 kHz microphone. Separate engines preserve
independent hardware clocks; conversion to/from 24 kHz stays at the network
boundary. Both engines are stopped and their observers removed together.
