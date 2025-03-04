import { navbar } from "vuepress-theme-hope";
import { readdirSync, statSync } from "fs";
import { join, parse } from "path";

const DOCS_PATH = join(__dirname, "..", "guide");

function getNavItems(dir: string, prefix: string = ""): any[] {
  const items: any[] = [];
  const files = readdirSync(dir);

  for (const file of files) {
    const fullPath = join(dir, file);
    const stat = statSync(fullPath);

    if (stat.isDirectory()) {
      // 处理目录
      const children = getNavItems(fullPath, `${prefix}${file}/`);
      if (children.length) {
        items.push({
          text: file,
          icon: "lightbulb",
          prefix: `${file}/`,
          children
        });
      }
    } else if (file.endsWith('.md') && file !== 'README.md') {
      // 处理 markdown 文件
      const name = parse(file).name;
      items.push(name);
    }
  }

  return items;
}

export default navbar([
  "/",
  "/demo/",
  {
    text: "模块",
    icon: "lightbulb",
    prefix: "/guide/",
    children: getNavItems(DOCS_PATH)
  },
  "/cases/",
]);
