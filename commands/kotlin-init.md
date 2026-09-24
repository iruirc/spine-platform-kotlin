---
description: "Create a new Kotlin project (Android app, Compose Desktop app, JVM server, CLI tool or KMP module) / Создать новый Kotlin-проект (Android, Compose Desktop, JVM-сервер, CLI или KMP-модуль)"
argument-hint: <project description>
---

Activate agent `@spine-platform-kotlin:kotlin-init` via the Task tool (`subagent_type=spine-platform-kotlin:kotlin-init`) with arguments: $ARGUMENTS

The agent generates **one Gradle build** — a root `settings.gradle.kts`, one application (or library) module for the chosen target, optional `:core:*` modules, a version catalog, ktlint/detekt configuration — and then hands the collected stack to `spine-toolkit:setup`, which writes `CLAUDE-spine-toolkit.md` and a minimal user-owned `CLAUDE.md`. It asks the target first and confirms every stack choice before generating. To attach the toolkit to an **already existing** project use `/setup`. It does not create a multi-repository workspace.
