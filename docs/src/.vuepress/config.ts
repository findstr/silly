import { defineUserConfig } from "vuepress";
import { viteBundler } from "@vuepress/bundler-vite";

import theme from "./theme.js";

export default defineUserConfig({
  base: "/silly/",

  locales: {
    "/": {
      lang: "zh-CN",
      title: "参考手册",
      description: "Silly 参考手册",
    },
    "/en/": {
      lang: "en-US",
      title: "Reference Manual",
      description: "Silly Reference Manual",
    },
  },

  theme,

  bundler: viteBundler(),

  // 和 PWA 一起启用
  // shouldPrefetch: false,
});
