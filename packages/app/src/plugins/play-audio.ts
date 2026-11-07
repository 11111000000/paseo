import { createAudioPlayer, setAudioModeAsync } from "expo-audio";
import { File, Paths } from "expo-file-system";
import { isNative, isWeb } from "@/constants/platform";

export interface PluginAudioPayload {
  base64: string;
  mimeType: string;
}

export type PluginAudioErrorCode = "invalid_payload" | "unsupported_format" | "playback_failed";

export class PluginAudioError extends Error {
  readonly code: PluginAudioErrorCode;

  constructor(code: PluginAudioErrorCode, message: string) {
    super(message);
    this.name = "PluginAudioError";
    this.code = code;
  }
}

const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
const MIME_PATTERN = /^audio\/[\w.+-]+(?:[ \t]*;[^\r\n]+)?$/i;

/** Container formats the platform players accept, mapped to a file extension. */
const EXTENSION_BY_MIME: Record<string, string> = {
  "audio/mpeg": "mp3",
  "audio/mp3": "mp3",
  "audio/wav": "wav",
  "audio/wave": "wav",
  "audio/x-wav": "wav",
  "audio/ogg": "ogg",
  "audio/opus": "opus",
  "audio/aac": "aac",
  "audio/mp4": "m4a",
  "audio/flac": "flac",
};

const PLAYBACK_TIMEOUT_MS = 120_000;

function extensionForMimeType(mimeType: string): string {
  const base = mimeType.split(";")[0].trim().toLowerCase();
  return EXTENSION_BY_MIME[base] ?? "bin";
}

/**
 * Play a base64-encoded audio file on this client.
 *
 * The payload arrives from a plugin RPC handler, so it is untrusted: base64 and
 * MIME type are validated before anything reaches the media stack. Raw PCM is
 * rejected — the platform players expect a container (WAV, MP3), and a
 * headerless PCM stream plays as noise.
 */
export async function playPluginAudio(payload: PluginAudioPayload): Promise<void> {
  const { base64, mimeType } = payload;

  if (
    typeof base64 !== "string" ||
    base64.length === 0 ||
    base64.length % 4 !== 0 ||
    !BASE64_PATTERN.test(base64)
  ) {
    throw new PluginAudioError(
      "invalid_payload",
      "Audio must contain a non-empty base64-encoded file",
    );
  }
  if (typeof mimeType !== "string" || !MIME_PATTERN.test(mimeType)) {
    throw new PluginAudioError(
      "invalid_payload",
      "Audio must have an audio MIME type, such as audio/wav",
    );
  }
  if (mimeType.split(";")[0].trim().toLowerCase() === "audio/pcm") {
    throw new PluginAudioError(
      "unsupported_format",
      "Pass an audio file, such as WAV or MP3; raw PCM is not supported",
    );
  }

  const bytes = new Uint8Array(Buffer.from(base64, "base64"));

  if (isNative) {
    await configurePlaybackAudioMode();
    const directory = Paths.cache ?? Paths.document;
    if (!directory) {
      throw new PluginAudioError("playback_failed", "No writable directory for audio playback");
    }
    const file = new File(
      directory,
      `paseo-plugin-audio-${Date.now()}.${extensionForMimeType(mimeType)}`,
    );
    file.create({ overwrite: true });
    await file.write(bytes);
    try {
      await playUri(file.uri);
    } finally {
      file.delete();
    }
    return;
  }

  if (isWeb) {
    const objectUrl = URL.createObjectURL(new Blob([bytes], { type: mimeType }));
    try {
      await playUri(objectUrl);
    } finally {
      URL.revokeObjectURL(objectUrl);
    }
    return;
  }

  throw new PluginAudioError("playback_failed", "Unsupported platform for audio playback");
}

/**
 * expo-audio defaults to `playsInSilentMode: false`, so a plugin sound would be
 * muted whenever the phone is on silent — the button would look broken.
 */
async function configurePlaybackAudioMode(): Promise<void> {
  await setAudioModeAsync({
    playsInSilentMode: true,
    interruptionMode: "mixWithOthers",
    interruptionModeAndroid: "duckOthers",
  });
}

async function playUri(uri: string): Promise<void> {
  const player = createAudioPlayer({ uri });

  let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
  let subscription: { remove(): void } | undefined;

  const finished = new Promise<void>((resolve, reject) => {
    subscription = player.addListener("playbackStatusUpdate", (status) => {
      if (status.didJustFinish) {
        resolve();
      }
    });
    // A decoder failure or a lost audio focus leaves the player silent without
    // ever reporting completion, so the wait needs its own ceiling.
    timeoutHandle = setTimeout(() => {
      reject(new PluginAudioError("playback_failed", "Audio playback did not finish in time"));
    }, PLAYBACK_TIMEOUT_MS);
  });

  try {
    player.play();
    await finished;
  } finally {
    if (timeoutHandle) {
      clearTimeout(timeoutHandle);
    }
    subscription?.remove();
    player.remove();
  }
}
