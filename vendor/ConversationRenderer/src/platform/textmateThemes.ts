const loaders = {
  "pierre-light": () => import("@tab-native/textmate/pierre-light"),
  "pierre-dark": () => import("@tab-native/textmate/pierre-dark"),
};
export const themes = {
  getTheme(name: string) {
    const load = loaders[name as keyof typeof loaders];
    return load ? { name, load } : undefined;
  },
};
