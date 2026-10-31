/** Browsers report a deferred ResizeObserver delivery as a no-exception ErrorEvent. */
export function classifyBrowserError(event: Pick<ErrorEvent, "message" | "error">) {
  const resizeNotification =
    event.error == null &&
    /^ResizeObserver loop (?:completed with undelivered notifications\.?|limit exceeded\.?)$/.test(
      event.message,
    );
  return {
    type: resizeNotification ? "renderDiagnostic" : "error",
    scope: resizeNotification ? "resize-observer" : "window",
    message: event.message,
  };
}
