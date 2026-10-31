/** A namespace import that turns into `void 0` is a runtime failure, not a shippable warning. */
export function rejectInvalidImports(warning, defaultHandler) {
  if (["IMPORT_IS_UNDEFINED", "MISSING_EXPORT", "UNRESOLVED_IMPORT"].includes(warning.code))
    throw new Error(`Invalid renderer import (${warning.code}): ${warning.message}`);
  defaultHandler(warning);
}
