import React, { useState } from "react";
import { RouterProvider } from "@tanstack/react-router";
import { EnvironmentId, ThreadId, TurnItemId } from "@conversation/contracts";
import { AppAtomRegistryProvider } from "@conversation-source/rpc/atomRegistry";
import { McpAppFrame } from "@conversation-source/components/chat/McpAppFrame";
import { mountConversation } from "../src/reactRoot";
import { ConversationProviders } from "../src/ConversationProviders";
import { createNativeConversationRouter } from "../src/platform/router";
import { setPlatformSnapshot } from "../src/platform/snapshot";
import { resolveNative, type ConversationSnapshot } from "../src/bridge";
import "../src/renderer.css";
let update: (snapshot: ConversationSnapshot) => void;
window.TabConversation = {
  update(snapshot) {
    setPlatformSnapshot(snapshot);
    update(snapshot);
  },
  resolve: resolveNative,
};
function Harness() {
  const [snapshot, setSnapshot] = useState<ConversationSnapshot>();
  update = setSnapshot;
  return (
    <ConversationProviders>
      {snapshot ? (
        <McpAppFrame
          environmentId={EnvironmentId.make("project")}
          threadId={ThreadId.make("mcp-fixture")}
          conversationThreadId={ThreadId.make("mcp-fixture")}
          itemId={TurnItemId.make("mcp-item")}
          revision="1"
          app={{
            attachmentId: "app-resource",
            server: "Fixture",
            tool: "show_app",
            resourceUri: "ui://fixture",
          }}
          onSendMessage={undefined}
        />
      ) : null}
    </ConversationProviders>
  );
}
const router = createNativeConversationRouter(Harness);
mountConversation(
  document.getElementById("root")!,
  <AppAtomRegistryProvider>
    <RouterProvider router={router} />
  </AppAtomRegistryProvider>,
);
