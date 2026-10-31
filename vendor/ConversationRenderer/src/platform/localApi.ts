import { nativeAction } from "../bridge";
import { reportNativeFailure } from "./bridgeActions";
import {
  showContextMenuFallback,
  dismissContextMenu,
} from "@conversation-source/contextMenuFallback";
const localApi = {
  shell: {
    openExternal: async (url: string) => {
      try {
        await nativeAction({ kind: "openLink", url });
      } catch (error) {
        reportNativeFailure(error, "Unable to open link");
        throw error;
      }
    },
  },
  contextMenu: {
    show: showContextMenuFallback,
    close: async () => {
      dismissContextMenu();
    },
  },
  clipboard: {
    writeText: async (text: string) => {
      await nativeAction({ kind: "copy", text });
    },
  },
};
export function readLocalApi() {
  return localApi;
}
export function ensureLocalApi() {
  return localApi;
}
export function createLocalApi() {
  return localApi;
}
