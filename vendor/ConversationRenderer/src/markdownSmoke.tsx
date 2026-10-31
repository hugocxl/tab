import React, { useState } from "react";
import { mountConversation } from "./reactRoot";
import { classifyBrowserError } from "./browserErrors";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import ChatMarkdown from "@conversation-source/components/ChatMarkdown";
import { AppAtomRegistryProvider } from "@conversation-source/rpc/atomRegistry";
import { applyAppearanceFontVariables } from "@conversation-source/appearanceFonts";
import "./renderer.css";
import { post, resolveNative, type ConversationSnapshot } from "./bridge";
import { installNativePlatform } from "./platform/bridgeActions";
import { setPlatformSnapshot } from "./platform/snapshot";
import { applyNativeTheme } from "./platform/nativeTheme";
installNativePlatform();
let receive: ((snapshot: ConversationSnapshot) => void) | undefined;
let latest: ConversationSnapshot | undefined;
window.TabConversation = {
  update(snapshot) {
    applyNativeTheme(snapshot);
    setPlatformSnapshot(snapshot);
    latest = snapshot;
    window.TabConversation.snapshot = snapshot;
    receive?.(snapshot);
  },
  resolve: resolveNative,
};
function Smoke() {
  const [snapshot, setSnapshot] = useState(latest);
  receive = setSnapshot;
  if (!snapshot) return null;
  document.documentElement.classList.toggle("dark", snapshot.theme === "dark");
  applyAppearanceFontVariables(document.documentElement, {
    sans: "",
    code: "",
    composer: "",
    sizeInterface: 16,
    sizePrompt: 14,
    sizeCode: 13,
    smoothing: true,
    separate: false,
  });
  return (
    <ChatMarkdown
      text={snapshot.messages[0]?.text ?? ""}
      cwd={snapshot.cwd}
      parseRawHtml={snapshot.messages[0]?.role !== "user"}
      lineBreaks={snapshot.messages[0]?.role === "user"}
      isStreaming={snapshot.messages[0]?.isStreaming}
    />
  );
}
const router = createRouter({
  routeTree: createRootRoute({ component: Smoke }),
  history: createMemoryHistory({ initialEntries: ["/"] }),
});
mountConversation(
  document.getElementById("root")!,
  <AppAtomRegistryProvider>
    <RouterProvider router={router} />
  </AppAtomRegistryProvider>,
);
window.addEventListener("error", (event) => post(classifyBrowserError(event)));
window.addEventListener("unhandledrejection", (event) =>
  post({ type: "error", message: String(event.reason) }),
);
post({ type: "ready" });
