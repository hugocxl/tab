import { nativeAction, post } from "../bridge";
import { toastManager, stackedThreadToast } from "@conversation-source/components/ui/toast";
export { nativeAction };
export function installNativePlatform() {
  const clipboard = {
    writeText: async (text: string) => {
      await nativeAction({ kind: "copy", text });
    },
    write: async (items: ClipboardItem[]) => {
      if (items.length > 8) throw new Error("Too many clipboard items.");
      const flavors: Record<string, string> = {};
      let png: Blob | undefined;
      for (const item of items)
        for (const type of item.types) {
          const blob = await item.getType(type);
          if (type === "image/png") {
            if (png) throw new Error("Multiple image clipboard items are unsupported.");
            png = blob;
          } else if (
            type.startsWith("text/") ||
            type.startsWith("web text/") ||
            type === "web application/x-tab-context-fragment+json"
          )
            flavors[type] = await blob.text();
          else throw new Error("Unsupported clipboard MIME type: " + type);
        }
      if (!png) {
        await nativeAction({
          kind: "copy",
          ...(flavors["text/plain"] !== undefined ? { text: flavors["text/plain"] } : {}),
          html: flavors["text/html"],
          flavors,
        });
        return;
      }
      if (!Number.isSafeInteger(png.size) || png.size <= 0)
        throw new Error("Invalid image clipboard size.");
      const transferId = await nativeAction({
        kind: "copy",
        phase: "begin",
        byteLength: png.size,
        flavors,
      });
      try {
        for (let offset = 0; offset < png.size; offset += 256 * 1024) {
          const bytes = new Uint8Array(await png.slice(offset, offset + 256 * 1024).arrayBuffer());
          let encoded = "";
          for (let index = 0; index < bytes.length; index += 32768)
            encoded += String.fromCharCode(...bytes.subarray(index, index + 32768));
          await nativeAction({
            kind: "copy",
            phase: "chunk",
            transferId,
            offset,
            dataBase64: btoa(encoded),
          });
        }
        await nativeAction({ kind: "copy", phase: "commit", transferId });
      } catch (error) {
        await nativeAction({ kind: "copy", phase: "abort", transferId }).catch(() => {});
        throw error;
      }
    },
  };
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: clipboard });
  window.open = (url?: string | URL, target?: string) => {
    if (url)
      void nativeAction({ kind: "openLink", url: String(url), target }).catch(reportNativeFailure);
    return null;
  };
}
const reportedNativeFailures = new WeakSet<object>();
export function reportNativeFailure(error: unknown, title = "Action failed") {
  if (error !== null && typeof error === "object") {
    if (reportedNativeFailures.has(error)) return;
    reportedNativeFailures.add(error);
  }
  const message = error instanceof Error ? error.message : String(error);
  toastManager.add(stackedThreadToast({ type: "error", title, description: message }));
  post({ type: "renderDiagnostic", scope: "native-action", message });
}
export function citeAssistantText(citation: unknown): boolean {
  return window.prompt("__tab_conversation_cite_v1__", JSON.stringify(citation)) === "true";
}
