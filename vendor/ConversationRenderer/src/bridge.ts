import type { HtmlRenderReference } from "@conversation/shared/htmlRender";
import type { McpAppReference } from "@conversation/shared/mcpApp";
import type { NativeViewportDescription } from "./nativeViewport";
export type NativeAction = { kind: string; [key: string]: unknown };
export interface ConversationMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  isStreaming?: boolean;
  createdAt?: string;
  turnId?: string;
  attachments?: unknown[];
  work?: unknown[];
}
export interface NativeConversationPalette {
  background: string;
  foreground: string;
  mutedForeground: string;
  dimForeground: string;
  surface: string;
  border: string;
  hover: string;
  accent: string;
  accentSoft: string;
  accentForeground: string;
  warning: string;
  danger: string;
  diffAdd: string;
  diffRemove: string;
  diffHunk: string;
  card: string;
  cardBorder: string;
  raised: string;
  floating: string;
  selection: string;
  syntax: {
    foreground: string;
    keyword: string;
    string: string;
    number: string;
    type: string;
    function: string;
    attribute: string;
    comment: string;
    punctuation: string;
  };
  ansi16: readonly string[];
}
export interface ConversationSnapshot {
  bridgeVersion: 1;
  sessionId: string;
  projectId?: string;
  environmentId?: string;
  provider?: string;
  title?: string;
  settings?: Record<string, unknown>;
  projects?: Array<Record<string, unknown>>;
  subagents?: Array<Record<string, unknown>>;
  revision: number;
  sequence?: number;
  theme: "light" | "dark";
  palette?: NativeConversationPalette;
  cwd?: string;
  viewport?: NativeViewportDescription;
  items: Array<Record<string, unknown>>;
  turns: Array<Record<string, unknown>>;
  status?: unknown;
  connectionState?: "live" | "cached" | "empty";
  messages: ConversationMessage[];
  font: { interfaceSize: number; promptSize: number; codeSize: number };
  capabilities?: Record<string, boolean>;
}
export interface NativeReply {
  requestId: string;
  ok: boolean;
  result?: unknown;
  error?: string;
}
export interface ConversationBridge {
  update(snapshot: ConversationSnapshot): void;
  resolve(reply: NativeReply): void;
  scrollToEnd?(): void;
  find?(action: "open" | "next" | "previous" | "close"): boolean;
  navigateCitation?(citation: unknown): boolean;
  prepareMcpDocument?(html: string, app: McpAppReference): string;
  htmlRenderReference?(toolName: string, output: unknown): HtmlRenderReference | null;
  snapshot?: ConversationSnapshot;
}
declare global {
  interface Window {
    TabConversation: ConversationBridge;
    webkit?: { messageHandlers?: { tabConversation?: { postMessage(message: unknown): void } } };
  }
}
const pending = new Map<
  string,
  {
    resolve(value: unknown): void;
    reject(error: Error): void;
    timeout: ReturnType<typeof setTimeout>;
  }
>();
let nextRequest = 0;
export function post(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.tabConversation?.postMessage({ bridgeVersion: 1, ...message });
}
export function nativeAction(action: NativeAction): Promise<unknown> {
  const requestId = String(++nextRequest);
  return new Promise((resolve, reject) => {
    if (!window.webkit?.messageHandlers?.tabConversation) {
      reject(new Error("The native conversation host is unavailable."));
      return;
    }
    const timeout = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error("The native conversation action timed out."));
    }, 30000);
    pending.set(requestId, { resolve, reject, timeout });
    try {
      post({ type: "action", requestId, action });
    } catch (error) {
      clearTimeout(timeout);
      pending.delete(requestId);
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}
export function resolveNative(reply: NativeReply): void {
  const request = pending.get(reply.requestId);
  if (!request) return;
  pending.delete(reply.requestId);
  clearTimeout(request.timeout);
  if (reply.ok) request.resolve(reply.result);
  else request.reject(new Error(reply.error ?? "The native action failed."));
}

window.addEventListener("pagehide", () => {
  for (const request of pending.values()) {
    clearTimeout(request.timeout);
    request.reject(new Error("The conversation page closed."));
  }
  pending.clear();
});
