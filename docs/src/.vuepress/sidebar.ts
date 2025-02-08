import { sidebar } from "vuepress-theme-hope";

export default sidebar({
  "/": [
    "",
    {
      text: "示例",
      icon: "laptop-code",
      prefix: "demo/",
      link: "demo/",
      children: "structure",
    },
    {
      text: "文档",
      icon: "book",
      prefix: "guide/",
      children: [
        {
          text: "密码学",
          icon: "lock",
          prefix: "crypto/",
          children: "structure",
        },
      ],
    },
  ],
});
