import type { ReactNode } from "react";
import { ToastProvider, AnchoredToastProvider } from "@conversation-source/components/ui/toast";
import { ConfirmDialogHost } from "@conversation-source/components/ConfirmDialogHost";

/** Source parent services are part of widget interactions, even though the composer is native. */
export function ConversationProviders({ children }: { children: ReactNode }) {
  return (
    <ToastProvider>
      <AnchoredToastProvider>
        {children}
        <ConfirmDialogHost />
      </AnchoredToastProvider>
    </ToastProvider>
  );
}
