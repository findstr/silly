---
home: true
icon: house
title: Home
bgImage: https://theme-hope-assets.vuejs.press/bg/6-light.svg
bgImageDark: https://theme-hope-assets.vuejs.press/bg/6-dark.svg
bgImageStyle:
  background-attachment: fixed
heroText: Silly
tagline: |
  A lightweight, minimalist high-performance Lua network framework.
actions:
  - text: Getting Started
    icon: rocket
    link: ./tutorials/
    type: primary

  - text: API Reference
    icon: book
    link: ./reference/

highlights:
  - header: Ready to Use
    image: /assets/image/box.svg
    bgImage: https://theme-hope-assets.vuejs.press/bg/3-light.svg
    bgImageDark: https://theme-hope-assets.vuejs.press/bg/3-dark.svg
    highlights:
      - title: Implement high-concurrency Echo server in 10 lines of code
        icon: smile-beam
        link: ./tutorials/

  - header: Rich Features
    description: Built on top of Lua, tons of features added for you to easily build high-concurrency servers.
    bgImage: https://theme-hope-assets.vuejs.press/bg/2-light.svg
    bgImageDark: https://theme-hope-assets.vuejs.press/bg/2-dark.svg
    bgImageStyle:
      background-repeat: repeat
      background-size: initial
    features:
      - title: silly.core
        icon: fa6-solid:circle-nodes
        details: Provides coroutine scheduling operations
        link: ./reference/silly.html

      - title: silly.net
        icon: fa6-solid:network-wired
        details: Provides tcp/udp/tls network operations
        link: ./reference/

      - title: silly.store
        icon: fa6-solid:database
        details: Provides redis/mysql/etcd storage system operations
        link: ./reference/

      - title: silly.sync
        icon: fa6-solid:sync
        details: Provides locks, queues, inter-coroutine communication and other synchronization operations
        link: ./reference/

      - title: silly.security
        icon: fa6-solid:shield
        details: Provides JWT and other security features
        link: ./reference/

      - title: silly.metrics
        icon: fa6-solid:chart-line
        details: Provides prometheus monitoring support
        link: ./reference/

      - title: silly.crypto
        icon: fa6-solid:lock
        details: Provides common cryptographic algorithms
        link: ./reference/

      - title: silly.encoding
        icon: fa6-solid:code
        details: Provides json/base64 encoding and decoding support
        link: ./reference/

      - title: silly.console
        icon: fa6-solid:terminal
        details: Provides console command line support
        link: ./reference/

      - title: silly.debugger
        icon: fa6-solid:bug
        details: Provides online debugger support
        link: ./reference/

      - title: silly.logger
        icon: fa6-solid:file-lines
        details: Provides logging support
        link: ./reference/logger.html

      - title: silly.patch
        icon: fa6-solid:arrows-rotate
        details: Provides hot reload support
        link: ./reference/

      - title: silly.adt
        icon: fa6-solid:box
        details: Provides efficient data structures (buffer, queue, etc.)
        link: ./reference/adt/

      - title: zproto
        icon: fa6-solid:code
        details: Provides protocol encoding and decoding support
        link: https://github.com/findstr/zproto

      - title: pb
        icon: fa6-solid:code
        details: Provides protobuf encoding and decoding support
        link: https://github.com/starwing/lua-protobuf

copyright: false
footer: Copyright © 2015-present 重归混沌 | Based on <a href="https://github.com/findstr/silly/tree/48f09ae9b">48f09ae9b</a>
---
