import type { NativeSyntheticEvent } from "react-native";
import { isImeComposingKeyboardEvent } from "@/utils/keyboard-ime";

/**
 * Shape of the native event emitted by React Native for hardware keyboard
 * key-down on `<TextInput onKeyDown>` (Android hardware keyboard and external
 * keyboard on iOS). Mirrors what RN actually passes; kept loose on purpose
 * because RN does not export a public type for it.
 */
export interface HardwareKeyDownEvent {
  key: string;
  keyCode?: number;
  isComposing?: boolean;
  shiftKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
}

export type HardwareEnterSubmitHandler = (
  event: NativeSyntheticEvent<HardwareKeyDownEvent>,
) => boolean;

/**
 * Returns a handler suitable for `<TextInput onKeyDown>` that invokes
 * `onSubmit` when a hardware-keyboard Enter is pressed without modifier
 * keys and outside of an IME composition session.
 *
 * Conventions (matches ChatGPT / Claude / Slack / Discord):
 *   - bare Enter       → submit (handler must call e.preventDefault())
 *   - Shift+Enter      → newline (default TextInput behaviour, untouched)
 *   - Ctrl/Cmd/Alt+Enter → newline (default TextInput behaviour, untouched)
 *
 * Why we need this on Android: hardware Enter on Android fires
 * `KeyEvent.KEYCODE_ENTER` which `ReactEditText` consumes as `\n`. Compose's
 * `imeAction` / `KeyboardActions(onSend)` only react to the soft keyboard's
 * "Send" button, never to hardware Enter. iOS is handled by a native module
 * (`paseo-hardware-keyboard`), so this helper is a no-op on iOS/web.
 *
 * Returns `true` if the event was consumed (caller should also call
 * `e.preventDefault()` to suppress the default `\n` insertion); `false`
 * otherwise so the native EditText can fall through to its default behaviour.
 */
export function createHardwareEnterSubmitHandler(
  onSubmit: () => void,
): HardwareEnterSubmitHandler {
  return (event) => {
    const native = event.nativeEvent;
    if (native.key !== "Enter") {
      return false;
    }
    // Don't submit during IME composition (e.g. CJK input methods
    // that use Enter to commit candidate text).
    if (isImeComposingKeyboardEvent(native)) {
      return false;
    }
    if (native.shiftKey || native.ctrlKey || native.altKey || native.metaKey) {
      return false;
    }
    onSubmit();
    // Prevent the EditText from inserting the default `\n` after submit.
    // (Android-only: iOS ignores preventDefault on hardware key events.)
    event.preventDefault();
    return true;
  };
}
