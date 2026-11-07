import Foundation

enum TranslateActions {
    /// 选中文字 → 浮层显示释义。再按一次收起。
    /// 顺序：本地词库（牛津英汉 → 朗文）命中就离线出结果，未命中才走在线翻译。
    static func translateSelection() {
        if TranslatePanel.shared.isShowing {
            TranslatePanel.shared.dismiss()
            Log.info("translate toggle off")
            return
        }

        guard let selected = AX.selectedText() else {
            Log.warn("translate failed reason=no-selection")
            return
        }
        let query = selected.trimmingCharacters(in: .whitespacesAndNewlines)
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
                Log.info("translate ok query=\(translation.query) lines=\(translation.lines.count) web=\(translation.webLines.count)")
                TranslatePanel.shared.show(result: translation)
            } else {
                let text = message ?? "未知错误"
                Log.warn("translate failed reason=\(text)")
                TranslatePanel.shared.show(error: text)
            }
        }
    }
}
