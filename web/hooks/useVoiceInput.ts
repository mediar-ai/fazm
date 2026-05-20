import { useState, useRef, useCallback, useEffect } from "react";

export const WAVEFORM_BARS = 5;
// Indices across the 128-bin frequency domain that give a pleasant spread
// across the audible voice range (low → high).
const FREQ_BINS = [3, 8, 18, 36, 64];

export function useVoiceInput(onTranscript: (text: string) => void) {
  const [recording, setRecording] = useState(false);
  const [transcribing, setTranscribing] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [audioLevels, setAudioLevels] = useState<number[]>(
    Array(WAVEFORM_BARS).fill(0),
  );

  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const recordingRef = useRef(false);
  const pendingStopRef = useRef(false);
  const statusTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const animFrameRef = useRef<number | null>(null);

  const showStatus = useCallback((msg: string) => {
    setStatusMessage(msg);
    if (statusTimerRef.current) clearTimeout(statusTimerRef.current);
    statusTimerRef.current = setTimeout(() => setStatusMessage(null), 3000);
  }, []);

  const stopAnimating = useCallback(() => {
    if (animFrameRef.current != null) {
      cancelAnimationFrame(animFrameRef.current);
      animFrameRef.current = null;
    }
    if (audioCtxRef.current) {
      audioCtxRef.current.close().catch(() => {});
      audioCtxRef.current = null;
    }
    analyserRef.current = null;
    setAudioLevels(Array(WAVEFORM_BARS).fill(0));
  }, []);

  const startAnimating = useCallback((stream: MediaStream) => {
    try {
      // Safari needs the webkit prefix for older versions.
      const Ctx =
        window.AudioContext ||
        (window as unknown as { webkitAudioContext: typeof AudioContext })
          .webkitAudioContext;
      const ctx = new Ctx();
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      analyser.smoothingTimeConstant = 0.75;
      ctx.createMediaStreamSource(stream).connect(analyser);
      audioCtxRef.current = ctx;
      analyserRef.current = analyser;
      const data = new Uint8Array(analyser.frequencyBinCount);
      const tick = () => {
        if (!analyserRef.current) return;
        analyserRef.current.getByteFrequencyData(data);
        setAudioLevels(FREQ_BINS.map((i) => Math.min(1, data[i] / 180)));
        animFrameRef.current = requestAnimationFrame(tick);
      };
      animFrameRef.current = requestAnimationFrame(tick);
    } catch {
      /* AudioContext unavailable — silently skip visualization */
    }
  }, []);

  const startRecording = useCallback(async () => {
    if (recordingRef.current) return;
    pendingStopRef.current = false;

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });

      // If stop was requested while we were waiting for mic permission
      if (pendingStopRef.current) {
        stream.getTracks().forEach((t) => t.stop());
        return;
      }

      startAnimating(stream);

      // Pick a supported mime type
      const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? "audio/webm;codecs=opus"
        : MediaRecorder.isTypeSupported("audio/webm")
          ? "audio/webm"
          : "audio/mp4";

      const mediaRecorder = new MediaRecorder(stream, { mimeType });
      mediaRecorderRef.current = mediaRecorder;
      chunksRef.current = [];

      mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      mediaRecorder.onstop = async () => {
        stream.getTracks().forEach((t) => t.stop());
        stopAnimating();
        recordingRef.current = false;
        setRecording(false);
        const blob = new Blob(chunksRef.current, { type: mimeType });
        if (blob.size === 0) {
          showStatus("No audio captured — hold the mic longer.");
          return;
        }

        setTranscribing(true);
        try {
          const res = await fetch("/api/transcribe", {
            method: "POST",
            headers: { "Content-Type": mimeType },
            body: blob,
          });
          if (!res.ok) {
            console.error("Transcribe failed:", res.status);
            showStatus("Transcription failed. Try again.");
            return;
          }
          const { transcript } = await res.json();
          if (transcript) {
            onTranscript(transcript);
          } else {
            showStatus("No speech detected. Try speaking closer to the mic.");
          }
        } catch (err) {
          console.error("Transcribe error:", err);
          showStatus("Transcription failed. Check your connection.");
        } finally {
          setTranscribing(false);
        }
      };

      mediaRecorder.start(100);
      recordingRef.current = true;
      setRecording(true);

      // If stop was requested during setup, stop immediately
      if (pendingStopRef.current) {
        mediaRecorder.stop();
      }
    } catch (err) {
      console.error("Mic access denied:", err);
      showStatus("Mic access denied. Grant permission in your browser.");
      recordingRef.current = false;
      setRecording(false);
      stopAnimating();
    }
  }, [onTranscript, startAnimating, stopAnimating, showStatus]);

  const stopRecording = useCallback(() => {
    pendingStopRef.current = true;
    if (mediaRecorderRef.current && mediaRecorderRef.current.state === "recording") {
      mediaRecorderRef.current.stop();
    }
  }, []);

  useEffect(() => {
    return () => {
      stopAnimating();
      if (statusTimerRef.current) clearTimeout(statusTimerRef.current);
    };
  }, [stopAnimating]);

  return {
    recording,
    transcribing,
    audioLevels,
    statusMessage,
    startRecording,
    stopRecording,
  };
}
