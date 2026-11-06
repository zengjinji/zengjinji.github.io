# zengjinji · Technical Notes / 技术手记

Hugo 中英文博客源码。默认英文首页：<https://zengjinji.github.io/>；中文首页：<https://zengjinji.github.io/zh/>。

- 本地源码目录：`/root/github/zengjinji.github.io`
- GitHub 仓库：<https://github.com/zengjinji/zengjinji.github.io>
- 生成目录：`public/`（不提交，GitHub Actions 自动生成）
- Hugo 版本：`.hugo-version`，本地与 CI 共用
- 自带主题：不依赖主题子模块、Node.js、外部字体或第三方 JavaScript

## 本地预览

```bash
cd /root/github/zengjinji.github.io
./scripts/hugo.sh server -D --bind 127.0.0.1
```

访问 <http://127.0.0.1:1313/>。`-D` 表示同时预览草稿，按 `Ctrl+C` 停止。

如果浏览器不在这台机器上，可在自己的电脑建立 SSH 端口转发：

```bash
ssh -L 1313:127.0.0.1:1313 root@你的服务器地址
```

再在自己电脑打开 <http://127.0.0.1:1313/>。

首次运行会下载官方 Hugo 并验证 SHA-256，程序只安装在本站 `.tools/hugo`，不修改系统环境。当前机器为 Linux x86_64。

## 中英文版本

导航栏的 **About / 关于** 右侧有语言切换按钮。首页、文章、归档、标签和关于页面会切换到对应页面的另一语言；某页尚未翻译时，按钮回到目标语言首页。默认英文由网址决定，不会根据浏览器语言自动跳转。

- `index.en.md` 是英文文章，`index.zh.md` 是中文文章，同放在一个文章目录中。
- 同一目录下的 `images/` 由两种语言共用，不用重复保存图片。
- `content/about.en.md`、`content/about.zh.md` 是关于页面。
- `i18n/en.toml`、`i18n/zh.toml` 保存界面文案。
- `hugo.toml` 的 `languages` 保存语言、站点标题和简介。
- 标签内部名称建议保持英文且两种语言一致；如需中文显示名，在 `content/tags/<tag>/_index.zh.md` 中设置 `title`，参考 `troubleshooting`。
- 英文 RSS 为 `/index.xml`，中文 RSS 为 `/zh/index.xml`。

现有文章：[English](https://zengjinji.github.io/posts/luajit-arm64-infinite-loop/) · [中文](https://zengjinji.github.io/zh/posts/luajit-arm64-infinite-loop/)。

## 新建文章

```bash
cd /root/github/zengjinji.github.io
./scripts/hugo.sh new content posts/my-first-note/index.en.md
./scripts/hugo.sh new content posts/my-first-note/index.zh.md
```

分别编辑 `content/posts/my-first-note/index.en.md` 与 `index.zh.md`，修改标题、简介、标签与正文。发布前将 `draft = true` 改为 `draft = false`，并检查日期没有设在未来。`slug` 决定文章网址，建议使用英文和连字符。

图片可放到文章的 `index.en.md` 与 `index.zh.md` 旁，用 `![图片说明](example.png)` 引用。

## 代码块排版

代码示例使用带语言标记的围栏代码块，例如 `lua`、`c`、`asm`、`diff`；JIT 日志、GDB 输出和文字过程图使用 `text`，保留缩进与对齐。

正文保持亮色，代码块及工具栏使用深色背景，并显示语言标签。复制按钮只复制代码正文，保留空格和换行；界面文字随中英文切换。浏览器不允许访问剪贴板时，会选中代码并提示手动复制。禁用 JavaScript 时仍可直接阅读和选择代码。

高亮配色由 `hugo.toml` 与 `static/css/main.css` 管理，代码块模板为 `layouts/_markup/render-codeblock.html`，复制逻辑为 `static/js/code-copy.js`。CSS 和复制脚本使用内容指纹，更新后无需等待旧资源缓存过期。

## 首次启用 GitHub Pages

1. 把本目录的源码提交并推送到仓库 `main` 分支（见下方）。
2. 打开 <https://github.com/zengjinji/zengjinji.github.io/settings/pages>。
3. 在 **Build and deployment → Source** 中选择 **GitHub Actions**。如果原来选择了 **Deploy from a branch**，必须切换，避免默认 Jekyll 部署覆盖 Hugo 页面。
4. 打开 <https://github.com/zengjinji/zengjinji.github.io/actions>，等待 `Build and deploy Hugo to GitHub Pages` 成功。首次切换发布来源后，在 Actions 中重新运行该流程，或推送一次新的源码提交以触发部署。
5. 访问 <https://zengjinji.github.io/>。

部署方式参考 [Hugo 官方指南](https://gohugo.io/host-and-deploy/deploy-to-github-pages/) 与 [GitHub Pages 官方说明](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)。无需购买域名，无需上传 `public/` 到源码分支。

## 后续发布

```bash
cd /root/github/zengjinji.github.io
# 先预览和构建
./scripts/hugo.sh --gc --minify --panicOnWarning
# 仅暂存本次需要发布的文件
git add content i18n archetypes hugo.toml layouts static scripts .github .hugo-version .gitignore README.md
git commit -m "Update blog"
./scripts/publish.sh
```

`publish.sh` 先构建，确认工作区没有未提交内容后通过代理推送 `main`；随后 GitHub Actions 自动发布。GitHub 认证使用你本机已配置的登录方式，脚本不保存访问令牌。

本机现有 SSH 密钥已验证属于 `zengjinji`，当前 checkout 配置为通过 `ssh.github.com:443` 与 HTTP CONNECT 代理推送，HTTPS 地址仍用于拉取。代理传输脚本为 `scripts/ssh-proxy.py`，GitHub 官方 SSH 主机公钥缓存在忽略的 `.tools/github-known-hosts`。这项配置仅保存在本地 `.git/config`，其他机器 clone 后可使用自己的 HTTPS 或 SSH 登录方式。

## 国内网络和代理

Git 命令按当前网络使用代理：

```bash
git -c http.proxy=http://172.20.10.1:1082 -c https.proxy=http://172.20.10.1:1082 push origin main
```

下载脚本和发布脚本默认使用 `http://172.20.10.1:1082`。可临时覆盖：

```bash
BLOG_PROXY=http://新的代理地址:端口 ./scripts/install-hugo.sh
# 不使用显式代理（GitHub Actions 使用此设置）
BLOG_PROXY= ./scripts/install-hugo.sh
BLOG_PROXY= ./scripts/publish.sh
```

GitHub 云端构建不使用本地代理地址。网页资源均位于本站，访客无需加载外部字体或脚本。

## 常用修改

| 要改什么 | 文件或目录 |
| --- | --- |
| 标题、描述、作者、网址 | `hugo.toml` |
| 界面与首页文字 | `i18n/en.toml`、`i18n/zh.toml` |
| 关于页面 | `content/about.en.md`、`content/about.zh.md` |
| 文章 | `content/posts/` |
| 样式 | `static/css/main.css` |
| 网站图标 | `static/favicon.svg` |
| 新文章模板 | `archetypes/default.md` |
| 自动部署 | `.github/workflows/hugo.yaml` |

本仓库的本地工作目录为 `/root/github/zengjinji.github.io`。后续在此目录写作、预览和推送。
