---
"hex-app": patch
---

Fix Hey Larry replies playing back truncated or not at all: the audio player was released as soon as playback started, and each reply leaked a temp WAV. Replies now play to completion, stop when you start speaking again, and log the reason when the endpoint is unreachable instead of falling back to dictation silently.
