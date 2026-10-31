export type NativeFindAction = "open" | "next" | "previous" | "close";
type FindHandler = (action: NativeFindAction) => boolean;
let handler: FindHandler | undefined;
let pending: NativeFindAction | undefined;

/** Module-ready can precede the first snapshot's React commit. */
export function requestNativeFind(action: NativeFindAction): boolean {
  if (!["open", "next", "previous", "close"].includes(action)) return false;
  if (handler) return handler(action);
  if (action === "close") {
    const queued = pending !== undefined;
    pending = undefined;
    return queued;
  }
  pending = action;
  return true;
}
/** Install only at the parent commit, then apply the user's accepted request. */
export function installNativeFind(next: FindHandler): () => void {
  handler = next;
  const queued = pending;
  pending = undefined;
  if (queued) next(queued);
  return () => {
    if (handler === next) handler = undefined;
  };
}
