---
name: video-edit
description: Edit long videos into short, story-driven clips using transcript analysis and ffmpeg. Use when user asks to "edit video", "cut video", "shorten video", "make highlight reel", "trim video", "create clip", or wants to extract the best moments from a recording. Works with screen recordings, demos, meetings, and any video with speech.
---

# Video Edit Skill

Edit long videos into concise, story-driven clips by analyzing the transcript, selecting key moments, and assembling them with ffmpeg.

## Workflow

### Phase 1: Discover & Transcribe

1. **Find the video** — locate file, get duration/format with `ffprobe`
2. **Extract audio** — convert to 16kHz mono WAV for transcription:
   ```bash
   ffmpeg -y -i INPUT -vn -acodec pcm_s16le -ar 16000 -ac 1 /tmp/audio.wav
   ```
3. **Transcribe with Whisper** — use `whisper` Python library (install via `pip3 install openai-whisper` if needed):
   ```python
   import whisper, json
   model = whisper.load_model("base")
   result = model.transcribe("/tmp/audio.wav", language="en", word_timestamps=True)
   # Save full result for reference
   with open("/tmp/transcript.json", "w") as f:
       json.dump(result, f)
   # Print timestamped segments
   for seg in result["segments"]:
       print(f'[{seg["start"]:.1f}-{seg["end"]:.1f}] {seg["text"].strip()}')
   ```

### Phase 2: Analyze & Select Moments

Read the full transcript and identify the **story arc**. Look for:

- **Setup**: Where the task/prompt is clearly stated
- **Progress beats**: AI working, intermediate results appearing
- **Positive reactions**: "wow", "that's great", "it worked", "cool", "upgraded", excitement
- **Key insights**: Moments where approach changes or something clever happens
- **Resolution**: Final confirmation that it worked, "thank you", wrap-up

**Selection rules:**
- Skip duplicate/repeated prompts (e.g., if there was a reset and the same prompt was given twice, use only the second clean attempt)
- Skip troubleshooting tangents, debugging, off-topic conversations, bathroom breaks, silence
- Skip filler ("uh", "hmm", long pauses) — but these are fine *within* a selected segment
- Keep segments long enough for context (15-75s each) — don't micro-cut
- Aim for 10-20% of original duration as a starting point
- Preserve the chronological order — never rearrange

**Present the plan to the user** before cutting — list each segment with timestamp range and what it captures.

### Phase 3: Extract & Assemble

1. **Extract each segment** as a separate file with re-encoding for clean cuts:
   ```bash
   ffmpeg -y -ss START -t DURATION -i INPUT \
     -c:v libx264 -preset fast -crf 23 \
     -c:a aac -b:a 128k \
     /tmp/segments/segNN.mp4
   ```

2. **Create concat file** and merge:
   ```bash
   for f in /tmp/segments/seg*.mp4; do
     echo "file '$f'" >> /tmp/segments/filelist.txt
   done
   ffmpeg -y -f concat -safe 0 -i /tmp/segments/filelist.txt \
     -c:v libx264 -preset fast -crf 23 \
     -c:a aac -b:a 128k \
     OUTPUT.mp4
   ```

3. **Verify** — check duration, file size, playback.

### Phase 4: Save

Save to the same directory as the source with `_edited` suffix, or as specified by user.

## Common Mistakes & Fixes

| Mistake | Fix |
|---------|-----|
| Including the first attempt when there was a reset/retry | Only include the clean second attempt — watch for repeated prompts |
| Cutting segments too short (<10s) | Keep 15-75s per segment for natural flow |
| Including long silences or "uh/hmm" segments | Skip segments that are mostly filler, but filler *within* a good segment is fine |
| Using `-c copy` for segment extraction | Always re-encode (`-c:v libx264`) — copy mode causes keyframe alignment issues and glitchy cuts |
| Forgetting `-safe 0` in concat | Required when using absolute paths in the file list |
| Rearranging chronological order | Never do this — the story must flow naturally in time |
| Over-compressing (too few segments) | The edit should still tell the complete story — don't skip important transitions |
| Including debugging/troubleshooting tangents | Skip unless the debugging itself is the story |

## What Makes a Good Edit

- **Tells a story**: setup → progress → "wow it worked" → done
- **Highlights positive outcomes**: reactions of surprise, satisfaction, confirmation
- **Shows the AI being smart**: clever approaches, autonomous decisions, learning
- **No dead time**: every second earns its place
- **Natural transitions**: segments should feel like they flow, even with jumps
- **User can follow along**: enough context in each segment to understand what's happening

## Dependencies

- `ffmpeg` / `ffprobe` (install via `brew install ffmpeg`)
- `whisper` Python library (install via `pip3 install openai-whisper`)
- Sufficient disk space for extracted audio + segments (rough guide: 2x source file size)
