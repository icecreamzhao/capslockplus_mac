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

        guard let selected = AX.selectedText() else {
            Log.warn("translate failed reason=no-selection")
            return
        }
        Log.info("translate source=ax")
        perform(selected)
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
