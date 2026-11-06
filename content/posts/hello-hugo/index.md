+++
title = '你好，Hugo：从第一篇文章开始'
date = '2026-11-06T09:00:00+08:00'
slug = 'hello-hugo'
description = '博客的第一篇示例文章：认识站点结构，写下第一段文字，让记录从今天开始。'
tags = ['Hugo', '博客搭建']
example = true
draft = false
+++
这是博客的第一篇**示例文章**。如果你能读到这里，说明 Hugo 已经把 Markdown 转换成了一个可以阅读的页面。

## 为什么写博客

很多问题解决之后，很快就会忘记当时的思路。把背景、尝试和结果写下来，既方便自己回看，也能帮助遇到类似问题的人。

不必等到文章足够完整才开始写。先记下一次实践，再慢慢补上细节。

> 好的记录，不只是留下答案，也留下寻找答案的过程。

## 这个博客怎样工作

整个过程很简单：

1. 在本地用 Markdown 写文章。
2. 使用 Hugo 预览和生成网页。
3. 把源码推送到 GitHub。
4. GitHub Actions 自动构建，并发布到 GitHub Pages。

你现在看到的标题、正文、目录和标签，都是由同一份 Markdown 生成的。

## 新建一篇文章

在博客目录执行：

```bash
cd /root/github/hugo
./scripts/hugo.sh new content posts/my-first-note/index.md
./scripts/hugo.sh server -D --bind 127.0.0.1
```

打开终端提示的本地地址，就能预览草稿。默认地址是 `http://127.0.0.1:1313/`。

文章顶部的 front matter 用来设置标题、日期、简介和标签：

```toml
title = '我的第一篇笔记'
slug = 'my-first-note'
description = '用一句话说明这篇文章讲什么。'
tags = ['笔记']
draft = false
```

正式发布前，把 `draft` 从 `true` 改为 `false`，并确认文章日期没有设在未来。

## 从一个小问题开始

可以从今天解决的一个问题写起：

- 当时遇到了什么现象？
- 你做过哪些尝试？
- 最终怎样解决？
- 下次还需要注意什么？

下一篇示例文章会展示 Markdown 的常用排版。
