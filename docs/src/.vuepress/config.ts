import { defineUserConfig } from "vuepress";

import theme from "./theme.js";

export default defineUserConfig({
  base: "/silly/",

  lang: "zh-CN",
  title: "参考手册",
  description: "Silly 参考手册",

  theme,

  // 和 PWA 一起启用
  // shouldPrefetch: false,
});
