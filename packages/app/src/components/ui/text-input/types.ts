import type { NativeSyntheticEvent, TextInputProps } from "react-native";
import type { NativePastedFile } from "@/composer/native-pasted-image";

export interface EditingTextInputHandle {
  focus(): void;
  blur(): void;
  isFocused(): boolean;
  getText(): string;
  replaceText(text: string, selection?: { start: number; end: number }): void;
  /** Clear the editor and reset its intrinsic layout, preserving focus intent. */
  reset(): void;
  getNativeRef(): unknown;
}

interface HardwareKeyDownEventData {
  key: string;
  keyCode?: number;
  isComposing?: boolean;
  shiftKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
}

export interface EditingTextInputProps
  extends Omit<TextInputProps, "defaultValue" | "onChangeText" | "value"> {
  initialValue?: string;
  onChangeText?: (text: string) => void;
  onPasteImages?: (files: readonly NativePastedFile[]) => void;
  onPasteError?: (message: string) => void;
  variant?: "default" | "bottom-sheet";
  /**
   * Android-only: fired for hardware keyboard key-down events (including
   * Enter from an external Bluetooth / USB keyboard). iOS ignores it;
   * web/desktop fall through to `onKeyPress`.
   *
   * Not part of React Native's `TextInputProps` typing until RN ships
   * public types for it (tracked upstream); declared here so consumers can
   * pass it through with type safety.
   */
  onKeyDown?: (event: NativeSyntheticEvent<HardwareKeyDownEventData>) => void;
}
