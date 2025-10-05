import { navbar } from "vuepress-theme-hope";

export default navbar([
  "/",
  {
    text: "教程",
    icon: "graduation-cap",
    link: "/tutorials/",
  },
  {
    text: "操作指南",
    icon: "book",
    link: "/guides/",
  },
  {
    text: "API参考",
    icon: "code",
    link: "/reference/",
  },
  {
    text: "原理解析",
    icon: "lightbulb",
    link: "/concepts/",
  },
]);
