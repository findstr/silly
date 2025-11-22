---
title: Concepts
index: true
icon: lightbulb
category:
  - Concepts
---

# Concepts

Deep dive into Silly framework's design philosophy and core concepts.

## Features

- **Understanding-Oriented**: Explains "why" not just "how"
- **Architectural Perspective**: Understanding framework design from a macro view
- **Best Practices**: Learn the considerations behind the design

## Core Concepts

### Coroutine Scheduling Model

Silly uses a single-threaded event loop + coroutine concurrency model for high-performance async I/O.

### Thread Architecture

The framework uses a 4-thread architecture: Worker, Socket, Timer, Monitor.

### Message System

All inter-thread communication is implemented through lock-free message queues.

## Content Coming Soon

We are working on more concept documentation, stay tuned!

## Related Resources

- [Tutorials](/en/tutorials/) - Learn through practice
- [API Reference](/en/reference/) - Find specific implementations
