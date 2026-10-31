import type { ConversationSnapshot } from "./bridge";
import { post } from "./bridge";
export interface NativeRectangle {
  x: number;
  y: number;
  width: number;
  height: number;
}
export interface NativeViewportDescription {
  mode: "conversation-body" | "full-pane";
  width: number;
  height: number;
  composer?: NativeRectangle;
}
const finite = (value: unknown, fallback = 0) =>
  typeof value === "number" && Number.isFinite(value) ? value : fallback;
export function resolveNativeViewport(
  snapshot: ConversationSnapshot,
  width: number,
  height: number,
) {
  const value = snapshot.viewport;
  const fullPane = value?.mode === "full-pane";
  const composer =
    fullPane && value?.composer
      ? {
          x: finite(value.composer.x),
          y: finite(value.composer.y),
          width: Math.max(0, finite(value.composer.width)),
          height: Math.max(0, finite(value.composer.height)),
        }
      : null;
  // Use the paired native viewport height so live window resizing does not
  // temporarily reinterpret an old composer rectangle against a new height.
  const composerInset = composer
    ? Math.max(0, Math.min(height, finite(value?.height, height) - composer.y))
    : 0;
  return {
    mode: fullPane ? ("full-pane" as const) : ("conversation-body" as const),
    width,
    height,
    composer,
    composerInset,
  };
}

/** Native hit testing uses the actual source portal geometry, never a duplicate control. */
export function observeNativeOverlays() {
  const selector =
    '[data-slot$="-popup"],[data-slot="menu-sub-content"],[role="dialog"],[role="alertdialog"],[data-slot="dialog-backdrop"],[data-slot="alert-dialog-backdrop"],[data-slot="toast-viewport"] > *';
  const nodes = new Set<Element>();
  let queued = false,
    disposed = false,
    frame = 0,
    last = "",
    animationUntil = 0;
  const resize = new ResizeObserver(() => schedule());
  const add = (element: Element) => {
    let changed = false;
    for (const node of [element, ...element.querySelectorAll(selector)])
      if (node.matches(selector) && !nodes.has(node)) {
        nodes.add(node);
        resize.observe(node);
        changed = true;
      }
    return changed;
  };
  const round = (value: number) => Math.round(value * 64) / 64;
  function measure() {
    queued = false;
    if (disposed) return;
    if (frame) {
      cancelAnimationFrame(frame);
      frame = 0;
    }
    const rects: NativeRectangle[] = [];
    let modal = false,
      animating = false;
    for (const node of nodes) {
      if (!node.isConnected) {
        nodes.delete(node);
        resize.unobserve(node);
        continue;
      }
      const style = getComputedStyle(node),
        rect = node.getBoundingClientRect();
      if (
        style.display === "none" ||
        style.visibility === "hidden" ||
        rect.width <= 0 ||
        rect.height <= 0
      )
        continue;
      if (
        node.getAttribute("aria-modal") === "true" ||
        node.getAttribute("role") === "alertdialog" ||
        node.matches('[data-slot="dialog-backdrop"],[data-slot="alert-dialog-backdrop"]')
      )
        modal = true;
      if (style.pointerEvents !== "none")
        rects.push({
          x: round(rect.x),
          y: round(rect.y),
          width: round(rect.width),
          height: round(rect.height),
        });
      if (node.getAnimations?.().some((animation) => animation.playState === "running"))
        animating = true;
    }
    const state = { type: "overlays", modal, rects };
    const signature = JSON.stringify(state);
    if (signature !== last) {
      last = signature;
      post(state);
    }
    if (animating && performance.now() < animationUntil) frame = requestAnimationFrame(measure);
  }
  function schedule() {
    if (disposed || queued) return;
    queued = true;
    queueMicrotask(measure);
  }
  add(document.body);
  const mutations = new MutationObserver((records) => {
    let changed = false;
    for (const record of records) {
      if (record.type === "childList") {
        for (const node of record.addedNodes)
          if (node instanceof Element) changed = add(node) || changed;
        for (const node of record.removedNodes)
          if (node instanceof Element)
            for (const current of nodes)
              if (node === current || node.contains(current)) {
                nodes.delete(current);
                resize.unobserve(current);
                changed = true;
              }
      } else if (record.target instanceof Element) {
        for (const node of nodes)
          if (record.target === node || record.target.contains(node)) {
            changed = true;
            break;
          }
      }
    }
    if (changed) schedule();
  });
  mutations.observe(document.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: [
      "style",
      "class",
      "hidden",
      "aria-hidden",
      "aria-modal",
      "data-open",
      "data-closed",
      "data-starting-style",
      "data-ending-style",
    ],
  });
  const transition = () => {
    animationUntil = performance.now() + 1000;
    schedule();
  };
  document.addEventListener("transitionrun", transition, true);
  document.addEventListener("transitionend", schedule, true);
  document.addEventListener("animationstart", transition, true);
  document.addEventListener("animationend", schedule, true);
  window.addEventListener("resize", schedule);
  document.addEventListener("scroll", schedule, true);
  schedule();
  return () => {
    post({ type: "overlays", modal: false, rects: [] });
    disposed = true;
    mutations.disconnect();
    resize.disconnect();
    cancelAnimationFrame(frame);
    document.removeEventListener("transitionrun", transition, true);
    document.removeEventListener("transitionend", schedule, true);
    document.removeEventListener("animationstart", transition, true);
    document.removeEventListener("animationend", schedule, true);
    window.removeEventListener("resize", schedule);
    document.removeEventListener("scroll", schedule, true);
  };
}
