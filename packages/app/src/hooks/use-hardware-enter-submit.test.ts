import { describe, expect, it, vi } from "vitest";
import type { NativeSyntheticEvent } from "react-native";
import {
  createHardwareEnterSubmitHandler,
  type HardwareKeyDownEvent,
} from "./use-hardware-enter-submit";

function makeEvent(native: HardwareKeyDownEvent): NativeSyntheticEvent<HardwareKeyDownEvent> {
  return { nativeEvent: native } as NativeSyntheticEvent<HardwareKeyDownEvent>;
}

describe("createHardwareEnterSubmitHandler", () => {
  it("submits and prevents default on bare Enter", () => {
    const submit = vi.fn();
    const preventDefault = vi.fn();
    const handler = createHardwareEnterSubmitHandler(submit);

    const handled = handler({
      ...makeEvent({ key: "Enter" }),
      preventDefault,
    } as unknown as NativeSyntheticEvent<HardwareKeyDownEvent>);

    expect(handled).toBe(true);
    expect(submit).toHaveBeenCalledOnce();
    expect(preventDefault).toHaveBeenCalledOnce();
  });

  it("ignores Enter with Shift held (newline)", () => {
    const submit = vi.fn();
    const preventDefault = vi.fn();
    const handler = createHardwareEnterSubmitHandler(submit);

    const handled = handler({
      ...makeEvent({ key: "Enter", shiftKey: true }),
      preventDefault,
    } as unknown as NativeSyntheticEvent<HardwareKeyDownEvent>);

    expect(handled).toBe(false);
    expect(submit).not.toHaveBeenCalled();
    expect(preventDefault).not.toHaveBeenCalled();
  });

  it("ignores Enter with Ctrl/Cmd/Alt held (newline)", () => {
    const submit = vi.fn();
    const preventDefault = vi.fn();
    const handler = createHardwareEnterSubmitHandler(submit);

    for (const modifiers of [
      { ctrlKey: true },
      { altKey: true },
      { metaKey: true },
    ]) {
      const handled = handler({
        ...makeEvent({ key: "Enter", ...modifiers }),
        preventDefault,
      } as unknown as NativeSyntheticEvent<HardwareKeyDownEvent>);

      expect(handled).toBe(false);
      expect(submit).not.toHaveBeenCalled();
    }
    expect(submit).not.toHaveBeenCalled();
  });

  it("ignores non-Enter keys", () => {
    const submit = vi.fn();
    const handler = createHardwareEnterSubmitHandler(submit);

    for (const key of ["a", "Tab", "Escape", "ArrowUp", "Backspace", " "]) {
      const handled = handler(makeEvent({ key }));
      expect(handled).toBe(false);
    }
    expect(submit).not.toHaveBeenCalled();
  });

  it("ignores Enter during IME composition (keyCode 229 / isComposing)", () => {
    const submit = vi.fn();
    const preventDefault = vi.fn();
    const handler = createHardwareEnterSubmitHandler(submit);

    expect(
      handler({
        ...makeEvent({ key: "Enter", keyCode: 229 }),
        preventDefault,
      } as unknown as NativeSyntheticEvent<HardwareKeyDownEvent>),
    ).toBe(false);
    expect(
      handler({
        ...makeEvent({ key: "Enter", isComposing: true }),
        preventDefault,
      } as unknown as NativeSyntheticEvent<HardwareKeyDownEvent>),
    ).toBe(false);

    expect(submit).not.toHaveBeenCalled();
    expect(preventDefault).not.toHaveBeenCalled();
  });
});
