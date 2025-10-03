---
home: true
icon: house
title: 主页
bgImage: https://theme-hope-assets.vuejs.press/bg/6-light.svg
bgImageDark: https://theme-hope-assets.vuejs.press/bg/6-dark.svg
bgImageStyle:
  background-attachment: fixed
heroText: Silly
tagline: |
  一个轻量级、极简的高性能Lua服务器框架。
actions:
  - text: 使用指南
    icon: lightbulb
    link: ./demo/
    type: primary

  - text: 文档
    icon: book
    link: ./guide/

highlights:
  - header: 开箱即用
    image: /assets/image/box.svg
    bgImage: https://theme-hope-assets.vuejs.press/bg/3-light.svg
    bgImageDark: https://theme-hope-assets.vuejs.press/bg/3-dark.svg
    highlights:
      - title: 10行代码实现高并发Echo服务器
        icon: smile-beam
        link: ./demo/EchoServer.md

  - header: 丰富的功能
    description: 在Lua的基础上，为您添加了成吨功能, 来轻松构建高并发服务器。
    bgImage: https://theme-hope-assets.vuejs.press/bg/2-light.svg
    bgImageDark: https://theme-hope-assets.vuejs.press/bg/2-dark.svg
    bgImageStyle:
      background-repeat: repeat
      background-size: initial
    features:
      - title: silly
        icon: fa6-solid:circle-nodes
        details: 提供coroutine调度操作
        link: ./guide/foo/

      - title: silly.net
        icon: fa6-solid:network-wired
        details: 提供tcp/udp/tls等网络操作
        link: ./guide/foo/

      - title: silly.net.cluster
        icon: fa6-solid:network-wired
        details: 提供自定义RPC支持, 用于高性能场合
        link: ./guide/foo/

      - title: silly.net.grpc
        icon: fa6-solid:network-wired
        details: 提供grpc服务端/客户端支持
        link: ./guide/foo/

      - title: silly.store
        icon: fa6-solid:database
        details: 提供redis/mysql/etcd等存储系统操作
        link: ./guide/foo/

      - title: silly.sync
        icon: fa6-solid:sync
        details: 提供锁、队列、协程间通信等同步操作
        link: ./guide/foo/

      - title: silly.net.http
        icon: fa6-solid:network-wired
        details: 提供http/https/http2协议支持
        link: ./guide/foo/

      - title: silly.net.websocket
        icon: fa6-solid:code
        details: 提供websocket支持
        link: ./guide/foo/

      - title: silly.metrics
        icon: fa6-solid:chart-line
        details: 提供prometheus监控支持
        link: ./guide/foo/

      - title: silly.crypto
        icon: fa6-solid:lock
        details: 提供常用的密码学算法
        link: ./guide/foo/

      - title: silly.console
        icon: fa6-solid:terminal
        details: 提供控制台命令行支持
        link: ./guide/foo/

      - title: silly.debugger
        icon: fa6-solid:bug
        details: 提供在线调试器支持
        link: ./guide/foo/

      - title: silly.net.dns
        icon: fa6-solid:network-wired
        details: 提供dns解析支持
        link: ./guide/foo/

      - title: silly.json
        icon: fa6-solid:code
        details: 提供json编解码支持
        link: ./guide/foo/

      - title: silly.logger
        icon: fa6-solid:code
        details: 提供日志记录支持
        link: ./guide/foo/

      - title: silly.patch
        icon: fa6-solid:code
        details: 提供热更新支持
        link: ./guide/foo/

      - title: zproto
        icon: fa6-solid:code
        details: 提供协议编解码支持
        link: https://github.com/findstr/zproto

      - title: pb
        icon: fa6-solid:code
        details: 提供protobuf编解码支持
        link: https://github.com/starwing/lua-protobuf

copyright: false
footer: 版权所有 © 2015-至今 重归混沌
---
