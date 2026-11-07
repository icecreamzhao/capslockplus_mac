import Foundation

enum TranslateActions {
    /// 选中文字 → 浮层显示释义。
    /// 优先级：浮层内部划选的词 > 当前 App 的选中文字。
    /// 浮层已开着且其中没有选区时，再按一次收起。
    static func translateSelection() {
        if TranslatePanel.shared.isShowing {
            if let picked = TranslatePanel.shared.selectionText {
                Log.info("translate source=panel query=\(picked)")
                perform(picked)
                return
            }
            TranslatePanel.shared.dismiss()
            Log.info("translate toggle off")
            return
        }

        attemptRead(attempt: 0)
    }

    /// 读选区：第一次读空就隔 150ms 再试，最多三次。
    /// 双击选词后立刻按热键时，目标 App 常常还没来得及把选区暴露给 AX。
    private static func attemptRead(attempt: Int) {
        if let text = AX.selectedTextDeep() {
            Log.info("translate source=ax attempt=\(attempt)")
            perform(text)
            return
        }
        guard attempt < 4 else {
            Log.warn("translate failed reason=no-selection attempts=\(attempt + 1)")
            TranslatePanel.shared.showHint("没有选中文字。先用鼠标选中一个单词或短语，再按 caps+t。")
            return
        }
        // 不在 tap 里 sleep，交给主队列稍后重试
        // 退避：150 / 250 / 400 / 600ms，累计约 1.4s —— 双击选词后浏览器发布选区偶尔比这还慢
        let delays: [Double] = [0.15, 0.25, 0.40, 0.60]
        let delay = delays[min(attempt, delays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            attemptRead(attempt: attempt + 1)
        }
    }

    /// 查词主流程：本地词库优先，未命中走在线。
    private static func perform(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Log.warn("translate failed reason=empty-selection")
            return
        }
        guard query.count <= 60 else {
            Log.warn("translate skipped reason=too-long len=\(query.count)")
            TranslatePanel.shared.show(error: "选中的内容太长（\(query.count) 字符），请只选单词或短语")
            return
        }

        let entries = OfflineDictionary.shared.lookup(query)
        if let first = entries.first {
            let audio = entries.compactMap { $0.audioPath }.first
            TranslatePanel.shared.show(entry: first, audio: audio)
            Log.info("dict hit query=\(query) hits=\(entries.count) source=\(first.source) lines=\(first.lines.count) audio=\(audio == nil ? 0 : 1)")
            return
        }

        Log.info("dict miss query=\(query) -> online")
        TranslatePanel.shared.showPending(query: query)
        TranslateService.fetch(query) { translation, message in
            if let translation = translation {
                Log.info("translate ok query=\(translation.query) engine=\(translation.engine) lines=\(translation.lines.count) web=\(translation.webLines.count)")
                TranslatePanel.shared.show(result: translation)
            } else {
                let text = message ?? "未知错误"
                Log.warn("translate failed reason=\(text)")
                TranslatePanel.shared.show(error: text)
            }
        }
    }
}
