import { navbar } from "vuepress-theme-hope";

export default navbar([
  "/en/",
  {
    text: "Tutorials",
    icon: "graduation-cap",
    link: "/en/tutorials/",
  },
  {
    text: "Guides",
    icon: "book",
    link: "/en/guides/",
  },
  {
    text: "API Reference",
    icon: "code",
    link: "/en/reference/",
  },
  {
    text: "Concepts",
    icon: "lightbulb",
    link: "/en/concepts/",
  },
]);
