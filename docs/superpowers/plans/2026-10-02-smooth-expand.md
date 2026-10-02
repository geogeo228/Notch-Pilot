# Smooth expand + background scan + focused-terminal quiet — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** «Чёлка» раскрывается плавно, главный поток не занят сканированием, и вопрос не раскрывается сам, если в фокусе окно Zed этой сессии.

**Architecture:** В режиме «у аппаратной чёлки» окно получает постоянную рамку 560×460: SwiftUI анимирует содержимое, а клики ограничены полоской пилюли через `HitShape`. Сканирование сессий переезжает в `actor ClaudeScanner`; `ClaudeMonitor` только публикует результат. Для Zed проверка «терминал в фокусе» сверяет заголовок окна в фокусе с папкой workspace сессии.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit (NSPanel), Swift concurrency (actor), libproc, AX API. Без зависимостей.

**Spec:** `docs/superpowers/specs/2026-10-02-smooth-expand-design.md`

## Global Constraints

- Собирает только Георгий: `nice -n 10 scripts/build.sh && scripts/run-offline.sh`. Тестового таргета нет, проверка — `sample` главного потока и вживую.
- Рамка окна в notch-режиме: `560 × 460` (`expandedPanelWidth`, `expandedPanelHeight`), прижата к верху экрана, `topGap = 0`.
- Свободный (перетаскиваемый) режим не меняется.
- Интерфейс `ClaudeMonitor` (`sessions`, `processCount`, `recentEvents`, `start`, `stop`) не меняется.
- Значение `suppressPermissionWhenFocused` из `UserDefaults` главнее нового дефолта `true`.
- Никакого сетевого кода (форк без сети).

## Review Focus

1. **Клик по строке меню рядом с чёлкой, панель свёрнута.** Ожидание: клик проходит в строку меню (прозрачная зона не перехватывает). Проверка — шаг вживую в Task 4.
2. **Перетаскивание пилюли из чёлки в свободное место и обратно.** Ожидание: в свободном режиме окно снова размером с пилюлю, в notch-режиме возвращается фиксированная рамка. Task 1, шаг 5.
3. **Смена экрана (внешний монитор / крышка).** Ожидание: рамка пересчитывается для нового экрана без анимации. Task 1, шаг 3 + Task 4.
4. **Заголовок окна Zed с именем файла** («Desktop — README.md»). Ожидание: сравнивается только часть до « — ». Task 3, шаг 2.
5. **Медленный диск / долгий проход сканера.** Ожидание: новые проходы пропускаются, пока идёт текущий; очереди задач нет. Task 2, шаг 3.

---

### Task 1: Окно постоянного размера в notch-режиме

**Files:**
- Modify: `Sources/NotchPilot/NotchWindow.swift` (`repositionForCurrentState` ~390, `updateCollapsed` ~638, `updateExpanded` ~655, `updatePillOffset` ~671, `ClickThroughHostingView.HitShape` и `hitTest` ~691–740)

**Interfaces:**
- Produces: `HitShape.centered(width: CGFloat, offsetX: CGFloat = 0, height: CGFloat? = nil)` — `nil` = на всю высоту (свободный режим, как раньше). `private func fixedNotchFrame() -> NSRect`.

- [ ] **Step 1: HitShape с высотой.** В `enum HitShape` заменить кейс и ветку `hitTest`:

```swift
        case centered(width: CGFloat, offsetX: CGFloat = 0, height: CGFloat? = nil)
```
```swift
        case .centered(let width, let offsetX, let height):
            // Notch mode: the window is a fixed 560×460 strip and only
            // the pill at the TOP edge should take clicks (AppKit y is
            // bottom-up). nil height = whole window (floating mode).
            let h = height ?? bounds.height
            region = CGRect(
                x: (bounds.width - width) / 2 + offsetX,
                y: bounds.height - h,
                width: width,
                height: h
            )
```

- [ ] **Step 2: Фиксированная рамка.** Рядом с `expandedFrame()` добавить:

```swift
    /// Notch mode: one fixed frame for collapsed AND expanded, so the
    /// expand animation is pure SwiftUI (no per-frame window resize +
    /// full re-layout). Transparent area passes clicks via hitShape.
    private func fixedNotchFrame() -> NSRect {
        let f = currentScreen.frame
        let w = Self.expandedPanelWidth
        let h = Self.expandedPanelHeight
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private var collapsedHitShape: ClickThroughHostingView<AnyView>.HitShape {
        let size = lastCollapsedSize
        return isHardwareNotchAnchored(on: currentScreen)
            ? .centered(width: size.width, offsetX: lastPillOffsetX, height: size.height)
            : .centered(width: size.width, offsetX: lastPillOffsetX)
    }
```

(Проверить тип `clickHost`: если это `ClickThroughHostingView<AnyView>`, сигнатура верна; иначе подставить фактический параметр типа.)

- [ ] **Step 3: Не ресайзить окно в notch-режиме.** В `updateCollapsed`, `updateExpanded`, `repositionForCurrentState` в начало ветки вычисления рамки:

```swift
        if isHardwareNotchAnchored(on: currentScreen) {
            let target = fixedNotchFrame()
            if frame != target { setFrame(target, display: true) }  // no animation
        } else {
            // existing animated setFrame code unchanged
        }
```

В `updateCollapsed` строку `clickHost.hitShape = .centered(width: size.width, offsetX: lastPillOffsetX)` заменить на `clickHost.hitShape = collapsedHitShape` (после `lastCollapsedSize = size`). В `updateExpanded` — `clickHost.hitShape = expanded ? .full : collapsedHitShape`. В `updatePillOffset` — `clickHost.hitShape = collapsedHitShape`. Ранний `if isExpanded { return }` в `updateCollapsed` оставить, но hitShape обновлять до него не нужно (в раскрытом виде он `.full`).

- [ ] **Step 4: Проверить, что `currentPillRect` не трогаем.** Он считает `y: f.maxY - h` от верха рамки — при фиксированной рамке это всё ещё прямоугольник пилюли. Изменений нет.

- [ ] **Step 5: Перетаскивание.** Прочитать `snapToReleaseLocation` (~478): после отпускания он вызывает пересчёт рамки. Убедиться, что путь идёт через `repositionForCurrentState` (там уже новая ветка). Если он ставит рамку сам через `collapsedFrame`, добавить ту же проверку `isHardwareNotchAnchored` → `fixedNotchFrame()`.

- [ ] **Step 6: Commit**

```bash
git add Sources/NotchPilot/NotchWindow.swift
git commit -m "Notch mode: fixed window frame, animate content only; hit-test pill strip"
```

### Task 2: Сканирование сессий в фоновом actor

**Files:**
- Create: `Sources/NotchPilot/ClaudeScanner.swift`
- Modify: `Sources/NotchPilot/ClaudeMonitor.swift` (состояние 48–74, методы 103–578 переезжают; `refresh` 92–101; `recentEvents` использует `readTail`)

**Interfaces:**
- Produces: `actor ClaudeScanner { func scan() -> (sessions: [ClaudeSession], processCount: Int); nonisolated static func readTail(_ url: URL, bytes: Int) -> String }`

- [ ] **Step 1: Перенос.** Механически (скриптом, без ручного переписывания логики):
  - из `ClaudeMonitor` вырезать свойства `activeThreshold`, `shownThreshold`, `parseCache`, `stickyContextTokens`, `stickyContextWindow`, `lastLiveClaudePIDs` и методы `loadSessions`, `mtime`, `decodeProjectName`, `parseLastEntryCached`, `parseLastEntry`, `classify`, `isDangerousShell`, `readTail`, `shortStatus`, `summarize`, `liveClaudeCwdCounts`, `countClaudeProcesses` — дословно;
  - вставить в `ClaudeScanner.swift`:

```swift
import Foundation

/// Georgi fork: session scanning off the main thread. Pure file IO +
/// libproc; owns the parse caches. ClaudeMonitor publishes the result.
actor ClaudeScanner {
    // ⟵ moved properties and methods go here verbatim

    func scan() -> (sessions: [ClaudeSession], processCount: Int) {
        (loadSessions(), countClaudeProcesses())
    }
}
```

  - `readTail` сделать `nonisolated static` (он без состояния); внутри перенесённого кода вызовы `readTail(` заменить на `Self.readTail(`.

- [ ] **Step 2: `recentEvents`.** В `ClaudeMonitor.recentEvents` вызов `readTail(` заменить на `ClaudeScanner.readTail(`.

- [ ] **Step 3: Новый `refresh`.**

```swift
    private let scanner = ClaudeScanner()
    private var scanInFlight = false

    private func refresh() {
        // Skip if the previous pass is still running (slow disk) — no
        // pile-up of tasks.
        guard !scanInFlight else { return }
        scanInFlight = true
        Task { @MainActor in
            let result = await scanner.scan()
            if result.sessions != sessions { sessions = result.sessions }
            if result.processCount != processCount { processCount = result.processCount }
            scanInFlight = false
        }
    }
```

- [ ] **Step 4: Sendable.** Если компилятор ругается на передачу `ClaudeSession`/`ToolAction` между actor'ами — добавить `: Sendable` к `struct ClaudeSession` и `enum ToolAction` (строки 4 и 16).

- [ ] **Step 5: Commit**

```bash
git add Sources/NotchPilot/ClaudeScanner.swift Sources/NotchPilot/ClaudeMonitor.swift
git commit -m "Move session scanning to a background actor (ClaudeScanner)"
```

### Task 3: Тишина, когда в фокусе окно Zed этой сессии

**Files:**
- Modify: `Sources/NotchPilot/BuddyPreferences.swift:406` (дефолт)
- Modify: `Sources/NotchPilot/TerminalJumper.swift` (`isTerminalFocused`, `focusZedWindow`)

**Interfaces:**
- Produces: `private static func zedWorkspaceRoot(forCwd cwd: String, bundleID: String) -> String?`

- [ ] **Step 1: Дефолт.**

```swift
        suppressPermissionWhenFocused = defaults.object(forKey: Self.suppressPermKey) as? Bool ?? true  // Georgi fork: was false
```

- [ ] **Step 2: Общий подбор workspace.** Вынести из `focusZedWindow` чтение базы и выбор самого длинного префикса в `zedWorkspaceRoot(forCwd:bundleID:)` (тот же код: `sqlite3 -readonly … where session_id is not null and paths != ''`, split по `\n`, фильтр `cwd == root || cwd.hasPrefix(root + "/")`, `max` по длине). `focusZedWindow` вызывает его. Добавить:

```swift
    /// Title of the focused window of `app` via Accessibility, or nil.
    private static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return nil }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
```

- [ ] **Step 3: Точная проверка для Zed.** В `isTerminalFocused`, в ветке non-tmux, заменить `return termApp.processIdentifier == frontmost.processIdentifier` на:

```swift
            guard termApp.processIdentifier == frontmost.processIdentifier else { return false }
            // Zed: all windows are one process — compare the focused
            // window's title (Zed shows the project folder name, maybe
            // followed by " — file") with this session's workspace.
            if let bid = termApp.bundleIdentifier, bid.hasPrefix("dev.zed.Zed"),
               let root = zedWorkspaceRoot(forCwd: cwd, bundleID: bid),
               let title = focusedWindowTitle(of: termApp) {
                let project = title.components(separatedBy: " — ").first ?? title
                return project == (root as NSString).lastPathComponent
            }
            return true
```

- [ ] **Step 4: Commit**

```bash
git add Sources/NotchPilot/BuddyPreferences.swift Sources/NotchPilot/TerminalJumper.swift
git commit -m "Quiet when the session's Zed window is focused; default suppress on"
```

### Task 4: Сборка и проверка

- [ ] **Step 1:** Георгий: `cd ~/Desktop/ПРОЕКТЫ/Notch-Pilot && nice -n 10 scripts/build.sh && scripts/run-offline.sh`. Ошибки компиляции → исправить и повторить.
- [ ] **Step 2:** Подождать 20 с, `sample <pid> 3`: в главном потоке нет `ClaudeMonitor.refresh`/`loadSessions` (было ~27 мс/с).
- [ ] **Step 3:** `sample <pid> 8`, пока Георгий водит мышью к чёлке и обратно: нет `setFrame`/полной раскладки окна на каждом кадре.
- [ ] **Step 4:** Георгий глазами: раскрытие и сворачивание плавные.
- [ ] **Step 5:** Клики: строка меню рядом с чёлкой (свёрнуто), верх окна под прозрачной частью (свёрнуто и раскрыто) — проходят.
- [ ] **Step 6:** Регресс: список сессий, «работает/спит», «В чат» → окно Zed, вопрос из 2–3 частей с мультивыбором, «отпустить» уводом мыши.
- [ ] **Step 7:** Task 3: тестовый вопрос, когда в фокусе окно `Desktop` → не раскрывается, только сигнал; в фокусе окно Биржи → раскрывается.
- [ ] **Step 8:** Перетащить пилюлю из чёлки в сторону и вернуть — позиция и размер корректны.
